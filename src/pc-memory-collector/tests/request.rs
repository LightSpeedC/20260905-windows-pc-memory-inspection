use rust_ai_pc_memory_collector::request::{
    prune_dir, recover_proc, scan_inbox, watch_inbox, RequestDirs, KEEP_RESULTS, MAX_REQUEST_BYTES, RESTART_EXIT_CODE,
};
use std::fs;
use std::path::Path;
use std::time::Duration;

const NOW: i64 = 1_791_072_306_007;

fn dirs() -> (tempfile::TempDir, RequestDirs) {
    let d = tempfile::tempdir().unwrap();
    let r = RequestDirs::new(&d.path().join("request"));
    r.ensure().unwrap();
    (d, r)
}

fn put(dir: &Path, name: &str, body: &str) {
    fs::write(dir.join(name), body).unwrap();
}

fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

fn read_json(path: &Path) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn 終了コードは_75_で_winsw_が異常終了として起動し直す() {
    assert_eq!(RESTART_EXIT_CODE, 75);
}

#[test]
fn 受信箱と_処理中_完了_失敗の置き場を作る() {
    let (d, r) = dirs();
    for n in ["inbox", "proc", "comp", "error"] {
        assert!(d.path().join("request").join(n).is_dir(), "{n} が無い");
    }
    r.ensure().unwrap(); // 何度呼んでもよい
}

#[test]
fn 再起動の依頼を受け取ると_処理中へ移し_再起動を求める() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261006-233700.json", r#"{"action":"restart","note":"exe を替えた"}"#);
    let s = scan_inbox(&r, NOW);
    assert!(s.restart);
    assert_eq!(s.accepted, ["req-20261006-233700.json"]);
    assert!(names(&r.inbox).is_empty(), "受信箱に残っている");
    assert_eq!(names(&r.proc), ["req-20261006-233700.json"]);
}

// 書きかけのファイルを読ませない。依頼者は、.tmp に書き、書き終えてから .json へ名前を変える
#[test]
fn tmp_は_書きかけなので_読まない() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261006-233700.tmp", r#"{"action":"rest"#);
    let s = scan_inbox(&r, NOW);
    assert!(!s.restart && s.accepted.is_empty() && s.rejected.is_empty());
    assert_eq!(names(&r.inbox), ["req-20261006-233700.tmp"]);
}

#[test]
fn json_として読めない依頼は_理由つきで_失敗へ移す() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261006-233701.json", "{ これは JSON ではない");
    let s = scan_inbox(&r, NOW);
    assert!(!s.restart);
    assert_eq!(s.rejected.len(), 1);
    assert!(names(&r.inbox).is_empty() && names(&r.proc).is_empty());
    let v = read_json(&r.error.join("req-20261006-233701.json"));
    assert_eq!(v["status"], "error");
    assert!(v["reason"].as_str().unwrap().contains("JSON"), "{v}");
}

#[test]
fn 知らない動作の依頼は_失敗へ移す() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261006-233702.json", r#"{"action":"format-disk"}"#);
    let s = scan_inbox(&r, NOW);
    assert!(!s.restart, "知らない動作を受け付けた");
    let v = read_json(&r.error.join("req-20261006-233702.json"));
    assert!(v["reason"].as_str().unwrap().contains("format-disk"), "{v}");
}

#[test]
fn 大きすぎる依頼は_読まずに失敗へ移す() {
    let (_d, r) = dirs();
    let big = format!(r#"{{"action":"restart","note":"{}"}}"#, "a".repeat(MAX_REQUEST_BYTES as usize));
    put(&r.inbox, "req-20261006-233703.json", &big);
    let s = scan_inbox(&r, NOW);
    assert!(!s.restart);
    let v = read_json(&r.error.join("req-20261006-233703.json"));
    assert!(v["reason"].as_str().unwrap().contains("大きすぎ"), "{v}");
}

#[test]
fn note_が長すぎる依頼は_失敗へ移す() {
    let (_d, r) = dirs();
    let note = "あ".repeat(201);
    put(&r.inbox, "req-20261006-233704.json", &format!(r#"{{"action":"restart","note":"{note}"}}"#));
    assert!(!scan_inbox(&r, NOW).restart);
    assert!(r.error.join("req-20261006-233704.json").exists());
}

#[test]
fn 名前が_req_json_の形でない依頼は_失敗へ移す() {
    let (_d, r) = dirs();
    put(&r.inbox, "do-it.json", r#"{"action":"restart"}"#);
    assert!(!scan_inbox(&r, NOW).restart);
    let v = read_json(&r.error.join("do-it.json"));
    assert!(v["reason"].as_str().unwrap().contains("名前"), "{v}");
}

#[test]
fn 依頼が複数あれば_全部を処理する() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261006-233705.json", r#"{"action":"x"}"#);
    put(&r.inbox, "req-20261006-233706.json", r#"{"action":"restart"}"#);
    let s = scan_inbox(&r, NOW);
    assert!(s.restart);
    assert_eq!(s.accepted, ["req-20261006-233706.json"]);
    assert_eq!(s.rejected.len(), 1);
}

// 再起動すると、依頼を受け取ったプロセスは消えている。新しいプロセスが、残った依頼を完了にし、新しい版を書く
#[test]
fn 再起動の依頼は_新しいプロセスが起動時に完了にして_新しい版を書く() {
    let (_d, r) = dirs();
    put(&r.proc, "req-20261006-233700.json", r#"{"action":"restart"}"#);
    let done = recover_proc(&r, NOW, "9.9.9");
    assert_eq!(done.len(), 1);
    assert!(names(&r.proc).is_empty());
    let v = read_json(&r.comp.join("req-20261006-233700.json"));
    assert_eq!(v["status"], "completed");
    assert_eq!(v["version"], "9.9.9");
    assert_eq!(v["completed_at"], "2026/10/04 09:05:06.007");
}

#[test]
fn 処理中に残った再起動以外の依頼は_中断として失敗へ移す() {
    let (_d, r) = dirs();
    put(&r.proc, "req-20261006-233701.json", "壊れている");
    recover_proc(&r, NOW, "9.9.9");
    let v = read_json(&r.error.join("req-20261006-233701.json"));
    assert!(v["reason"].as_str().unwrap().contains("中断"), "{v}");
}

#[test]
fn 完了と失敗は_100_件まで_古いものから消す() {
    let (_d, r) = dirs();
    for i in 0..105 {
        put(&r.comp, &format!("req-20261006-{:06}.json", i), "{}");
    }
    prune_dir(&r.comp, KEEP_RESULTS);
    let left = names(&r.comp);
    assert_eq!(left.len(), 100);
    assert_eq!(left[0], "req-20261006-000005.json", "古い順に 5 件消える");
}

// OS のファイル監視。通知が来る（待ちを起こせる）こと。区切りの時刻を待たずに、依頼を受け取るための土台
#[test]
fn 受信箱にファイルができると_監視の通知が来る() {
    let (_d, r) = dirs();
    let (_watcher, rx) = watch_inbox(&r.inbox).unwrap();
    put(&r.inbox, "req-20261006-233700.tmp", "{}");
    rx.recv_timeout(Duration::from_secs(5)).expect("5 秒待っても、監視の通知が来ない");
}
