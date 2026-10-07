//! 依頼の受信箱。収集はポートを待ち受けないので、フォルダを OS のファイル監視で見て、依頼のファイルを受け取る。
//!
//! ```text
//! inbox/req-yyyymmdd-hhmmss.tmp   依頼者が書く（書きかけ。読まない）
//! inbox/req-yyyymmdd-hhmmss.json  書き終えたら、名前を変える
//! proc/…   受け取ったら、名前を変えて処理中へ（名前を変える操作で受け取るので、2 回受け取らない）
//! comp/…   完了（結果を書き足す）
//! error/…  失敗（理由を書き足す。黙って捨てない）
//! ```
//!
//! 依頼から、コマンドは実行しない。動作は、決まった一覧（`restart`・`inspect`）と照合する。
//! `inspect` は、いまのプロセスの上位 N 件とシステム全体の値を、`comp/` の結果に書く（プロセスは終了しない。読み取りだけ）。
//! 再起動は、受け取ったプロセスが終了コード 75 で終わり、winsw の「異常終了なら起動し直す」が、新しい exe で起動し直す。
//! 起動し直したプロセスが、処理中に残った再起動の依頼を完了にして、新しい版を書く（新しい exe で動いている証拠）。

use crate::collect::{ProcessInfo, SystemMemory};
use crate::timeutil::format_jst;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver};

/// 再起動の依頼を受けて終わるときの終了コード（`EX_TEMPFAIL`）。0 以外なので、winsw が起動し直す
pub const RESTART_EXIT_CODE: i32 = 75;
pub const MAX_REQUEST_BYTES: u64 = 4096;
pub const MAX_NOTE_CHARS: usize = 200;
pub const KEEP_RESULTS: usize = 100;

#[derive(Debug, Clone)]
pub struct RequestDirs {
    pub inbox: PathBuf,
    pub proc: PathBuf,
    pub comp: PathBuf,
    pub error: PathBuf,
}

impl RequestDirs {
    pub fn new(root: &Path) -> RequestDirs {
        RequestDirs { inbox: root.join("inbox"), proc: root.join("proc"), comp: root.join("comp"), error: root.join("error") }
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        for d in [&self.inbox, &self.proc, &self.comp, &self.error] {
            fs::create_dir_all(d)?;
        }
        Ok(())
    }
}

/// inspect の並び順
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InspectSort {
    /// コミット（プロセスのページファイル使用量。sysinfo の virtual_memory）
    Commit,
    WorkingSet,
}

/// inspect の引数。top は 1〜100（既定 20）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InspectParams {
    pub top: usize,
    pub sort: InspectSort,
}

pub const DEFAULT_INSPECT_TOP: usize = 20;
pub const MAX_INSPECT_TOP: usize = 100;

#[derive(Debug, Clone, Copy)]
enum Action {
    Restart,
    Inspect(InspectParams),
}

#[derive(Debug, Default)]
pub struct Scan {
    /// 再起動を求められた
    pub restart: bool,
    /// 受け取った再起動の依頼の名前
    pub accepted: Vec<String>,
    /// 受け取った inspect の依頼（名前, 引数）。処理中に置いたまま。呼び出し側が結果を作り、`complete_inspect` で完了にする
    pub inspects: Vec<(String, InspectParams)>,
    /// 受け付けなかった依頼（名前, 理由）
    pub rejected: Vec<(String, String)>,
}

fn valid_name(name: &str) -> bool {
    name.starts_with("req-") && name.ends_with(".json") && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// 依頼の中身を検査する。動作は、決まった一覧（restart・inspect）だけ
fn parse_request(text: &str) -> Result<(serde_json::Value, Action), String> {
    let v: serde_json::Value = serde_json::from_str(text).map_err(|e| format!("JSON として読めません: {e}"))?;
    let obj = v.as_object().ok_or("JSON の最上位がオブジェクトではありません")?;
    let action = match obj.get("action").and_then(|a| a.as_str()) {
        Some("restart") => Action::Restart,
        Some("inspect") => {
            let top = match obj.get("top") {
                None => DEFAULT_INSPECT_TOP,
                Some(t) => match t.as_u64() {
                    Some(n) if (1..=MAX_INSPECT_TOP as u64).contains(&n) => n as usize,
                    _ => return Err(format!("top は 1〜{MAX_INSPECT_TOP} の整数です")),
                },
            };
            let sort = match obj.get("sort") {
                None => InspectSort::Commit,
                Some(s) => match s.as_str() {
                    Some("commit") => InspectSort::Commit,
                    Some("working_set") => InspectSort::WorkingSet,
                    _ => return Err("sort は commit か working_set です".to_string()),
                },
            };
            Action::Inspect(InspectParams { top, sort })
        }
        Some(other) => return Err(format!("知らない動作です: {other}")),
        None => return Err("action がありません".to_string()),
    };
    if let Some(note) = obj.get("note") {
        let n = note.as_str().ok_or("note が文字列ではありません")?;
        if n.chars().count() > MAX_NOTE_CHARS {
            return Err(format!("note が長すぎます（{MAX_NOTE_CHARS} 文字まで）"));
        }
    }
    Ok((v, action))
}

/// inspect の結果を作る。コマンドラインと実行ファイルのパスは、含めない（資格情報が入りうる。結果は、依頼者が読み、資料や会話に貼られうる）。
/// 読めなかった値は、0 ではなく null
pub fn inspect_result(procs: &[ProcessInfo], mem: &SystemMemory, top: usize, sort: InspectSort) -> serde_json::Value {
    let key = |p: &ProcessInfo| match sort {
        InspectSort::Commit => p.virtual_bytes,
        InspectSort::WorkingSet => p.memory_bytes,
    };
    let mut order: Vec<&ProcessInfo> = procs.iter().collect();
    // 大きい順。読めなかったもの（None）は最後。同じ値は pid の小さい順
    order.sort_by(|a, b| key(b).cmp(&key(a)).then(a.pid.cmp(&b.pid)));
    let list: Vec<serde_json::Value> = order
        .into_iter()
        .take(top)
        .map(|p| {
            serde_json::json!({
                "pid": p.pid,
                "process_name": p.name,
                "commit_bytes": p.virtual_bytes,
                "working_set_bytes": p.memory_bytes,
                "started_at": format_jst(p.start_time_ms),
                "parent_pid": p.parent_pid,
            })
        })
        .collect();
    serde_json::json!({
        "sort": match sort { InspectSort::Commit => "commit", InspectSort::WorkingSet => "working_set" },
        "process_count": procs.len(),
        "processes": list,
        "system": {
            "phys_total": mem.phys_total,
            "phys_avail": mem.phys_avail,
            "swap_total": mem.swap_total,
            "swap_used": mem.swap_used,
            "commit_limit": mem.commit_limit,
            "commit_used": mem.commit_used,
            "pagefile_used": mem.pagefile_used,
            "pagefile_peak": mem.pagefile_peak,
            "kernel_paged": mem.kernel_paged,
            "kernel_nonpaged": mem.kernel_nonpaged,
            "system_cache": mem.system_cache,
        },
    })
}

/// inspect の依頼を完了にする。処理中の依頼に、結果と時刻と版を書き足して、`comp/` に置く
pub fn complete_inspect(dirs: &RequestDirs, name: &str, now_ms: i64, version: &str, result: &serde_json::Value) {
    let path = dirs.proc.join(name);
    let request: serde_json::Value = fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(serde_json::Value::Null);
    write_json(
        &dirs.comp.join(name),
        &serde_json::json!({
            "status": "completed",
            "completed_at": format_jst(now_ms),
            "version": version,
            "request": request,
            "result": result,
        }),
    );
    let _ = fs::remove_file(&path);
}

fn write_json(path: &Path, v: &serde_json::Value) {
    let _ = fs::write(path, serde_json::to_string_pretty(v).unwrap_or_default());
}

fn truncate(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

/// 依頼を失敗へ移す。元の中身（先頭だけ）と理由を書き、元のファイルは消す
fn move_to_error(dirs: &RequestDirs, name: &str, original: &Path, reason: &str, now_ms: i64) {
    let size = fs::metadata(original).map(|m| m.len()).unwrap_or(0);
    let text = if size <= MAX_REQUEST_BYTES { fs::read_to_string(original).unwrap_or_default() } else { String::new() };
    write_json(
        &dirs.error.join(name),
        &serde_json::json!({
            "status": "error",
            "reason": reason,
            "finished_at": format_jst(now_ms),
            "request": truncate(&text, 200),
        }),
    );
    let _ = fs::remove_file(original);
}

/// 受信箱を走査して、依頼を受け取る。通知は「起こすきっかけ」で、受け取りは、必ず、この走査で行う（通知の取りこぼしに備える）
pub fn scan_inbox(dirs: &RequestDirs, now_ms: i64) -> Scan {
    let mut scan = Scan::default();
    let Ok(rd) = fs::read_dir(&dirs.inbox) else { return scan };
    let mut files: Vec<String> = rd
        .flatten()
        .filter(|e| e.path().is_file())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.ends_with(".tmp")) // 書きかけは読まない
        .collect();
    files.sort();

    for name in files {
        let from = dirs.inbox.join(&name);
        if !valid_name(&name) {
            let reason = "名前が req-*.json の形ではありません".to_string();
            move_to_error(dirs, &name, &from, &reason, now_ms);
            scan.rejected.push((name, reason));
            continue;
        }
        // 名前を変えて受け取る。書き手がまだ掴んでいて変えられないときは、次の走査で受け取る
        let to = dirs.proc.join(&name);
        if fs::rename(&from, &to).is_err() {
            continue;
        }
        let size = fs::metadata(&to).map(|m| m.len()).unwrap_or(0);
        let checked = if size > MAX_REQUEST_BYTES {
            Err(format!("大きすぎます（{size} byte。上限 {MAX_REQUEST_BYTES} byte）"))
        } else {
            fs::read_to_string(&to).map_err(|e| format!("読めません: {e}")).and_then(|t| parse_request(&t))
        };
        match checked {
            Ok((_, Action::Restart)) => {
                scan.restart = true;
                scan.accepted.push(name);
            }
            // 処理中に置いたまま。結果を作って完了にするのは、呼び出し側（プロセスの一覧を取れるのは収集だけ）
            Ok((_, Action::Inspect(params))) => scan.inspects.push((name, params)),
            Err(reason) => {
                move_to_error(dirs, &name, &to, &reason, now_ms);
                scan.rejected.push((name, reason));
            }
        }
    }
    prune_dir(&dirs.comp, KEEP_RESULTS);
    prune_dir(&dirs.error, KEEP_RESULTS);
    scan
}

/// 起動時に、処理中に残った依頼を片付ける。再起動の依頼は、再起動が済んだので完了にして、新しい版を書く。
/// それ以外（読めない・再起動でない）は、中断されたものとして失敗へ移す。結果の説明文を返す
pub fn recover_proc(dirs: &RequestDirs, now_ms: i64, version: &str) -> Vec<String> {
    let mut messages = Vec::new();
    let Ok(rd) = fs::read_dir(&dirs.proc) else { return messages };
    let mut files: Vec<String> = rd.flatten().filter(|e| e.path().is_file()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    files.sort();
    for name in files {
        let path = dirs.proc.join(&name);
        let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let parsed = if size > MAX_REQUEST_BYTES { Err("大きすぎます".to_string()) } else { fs::read_to_string(&path).map_err(|e| e.to_string()).and_then(|t| parse_request(&t)) };
        match parsed {
            // inspect は、取った時点の値でないと意味が無いので、やり直さない
            Ok((_, Action::Inspect(_))) => {
                let reason = "処理の途中で中断されました（inspect はやり直しません。もう一度依頼してください）".to_string();
                move_to_error(dirs, &name, &path, &reason, now_ms);
                messages.push(format!("処理中に残った依頼を失敗にしました（{name}）: {reason}"));
            }
            Ok((request, Action::Restart)) => {
                write_json(
                    &dirs.comp.join(&name),
                    &serde_json::json!({
                        "status": "completed",
                        "completed_at": format_jst(now_ms),
                        "version": version,
                        "request": request,
                    }),
                );
                let _ = fs::remove_file(&path);
                messages.push(format!("再起動の依頼を完了しました（{name}、v{version}）"));
            }
            Err(e) => {
                let reason = format!("処理の途中で中断されました（{e}）");
                move_to_error(dirs, &name, &path, &reason, now_ms);
                messages.push(format!("処理中に残った依頼を失敗にしました（{name}）: {reason}"));
            }
        }
    }
    prune_dir(&dirs.comp, KEEP_RESULTS);
    prune_dir(&dirs.error, KEEP_RESULTS);
    messages
}

/// 名前の古い順に、`keep` 件を超えた分を消す
pub fn prune_dir(dir: &Path, keep: usize) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut files: Vec<String> = rd.flatten().filter(|e| e.path().is_file()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    files.sort();
    if files.len() > keep {
        for name in &files[..files.len() - keep] {
            let _ = fs::remove_file(dir.join(name));
        }
    }
}

/// 受信箱を OS のファイル監視で見る（Windows は ReadDirectoryChangesW）。変更があるたびに、通知が届く。
/// 戻り値の監視（Watcher）は、持っている間だけ動く。通知は「走査のきっかけ」で、内容は見ない
pub fn watch_inbox(inbox: &Path) -> Result<(RecommendedWatcher, Receiver<()>), String> {
    let (tx, rx) = channel();
    let mut watcher = notify::recommended_watcher(move |_event: notify::Result<notify::Event>| {
        let _ = tx.send(());
    })
    .map_err(|e| format!("ファイル監視を始められません: {e}"))?;
    watcher.watch(inbox, RecursiveMode::NonRecursive).map_err(|e| format!("受信箱を監視できません: {e}"))?;
    Ok((watcher, rx))
}
