// 依頼 inspect（いまのプロセスの状態を、受信箱の依頼で調べる）。再起動の依頼は tests/request.rs
use rust_ai_pc_memory_collector::collect::{ProcessInfo, SystemMemory};
use rust_ai_pc_memory_collector::request::{complete_inspect, inspect_result, recover_proc, scan_inbox, InspectSort, RequestDirs};
use std::fs;
use std::path::Path;

const NOW: i64 = 1_791_072_306_007;
const GB: u64 = 1024 * 1024 * 1024;

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

fn proc_of(pid: u32, name: &str, working_set: Option<u64>, commit: Option<u64>) -> ProcessInfo {
    ProcessInfo {
        pid,
        parent_pid: Some(1),
        start_time_ms: NOW,
        name: name.to_string(),
        exe_path: Some(format!("C:/x/{name}")),
        // 資格情報を含みうる。結果のファイルに出てはいけない
        command_line: Some("a.exe --token SECRET-VALUE".to_string()),
        cpu_total_ms: Some(1),
        memory_bytes: working_set,
        virtual_bytes: commit,
    }
}

fn mem() -> SystemMemory {
    SystemMemory {
        phys_total: 32 * GB,
        phys_avail: 7 * GB,
        swap_total: None,
        swap_used: None,
        commit_limit: Some(56 * GB),
        commit_used: Some(54 * GB),
        pagefile_used: Some(GB),
        pagefile_peak: None,
        kernel_paged: None,
        kernel_nonpaged: None,
        system_cache: None,
    }
}

fn sample() -> Vec<ProcessInfo> {
    vec![
        proc_of(10, "small.exe", Some(GB), Some(GB)),
        proc_of(20, "big.exe", Some(2 * GB), Some(6 * GB)),
        proc_of(30, "unreadable.exe", None, None),
        proc_of(40, "wsbig.exe", Some(5 * GB), Some(2 * GB)),
    ]
}

fn pids(v: &serde_json::Value) -> Vec<i64> {
    v["processes"].as_array().unwrap().iter().map(|p| p["pid"].as_i64().unwrap()).collect()
}

#[test]
fn inspect_の依頼は_処理中のまま受け取り_再起動を求めない_引数の既定は_上位_20_件_コミット順() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261007-120000.json", r#"{"action":"inspect"}"#);
    let s = scan_inbox(&r, NOW);
    assert!(!s.restart, "inspect で再起動を求めた");
    assert_eq!(s.inspects.len(), 1);
    assert_eq!(s.inspects[0].0, "req-20261007-120000.json");
    assert_eq!(s.inspects[0].1.top, 20);
    assert_eq!(s.inspects[0].1.sort, InspectSort::Commit);
    assert_eq!(names(&r.proc), ["req-20261007-120000.json"], "完了するまで、処理中に置く");
}

#[test]
fn inspect_の_top_と_sort_を指定できる() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261007-120000.json", r#"{"action":"inspect","top":5,"sort":"working_set","note":"急増の調査"}"#);
    let s = scan_inbox(&r, NOW);
    assert_eq!(s.inspects[0].1.top, 5);
    assert_eq!(s.inspects[0].1.sort, InspectSort::WorkingSet);
}

#[test]
fn inspect_の_範囲外の_top_と_知らない_sort_は_理由つきで失敗へ移す() {
    for body in [
        r#"{"action":"inspect","top":0}"#,
        r#"{"action":"inspect","top":101}"#,
        r#"{"action":"inspect","top":"20"}"#,
        r#"{"action":"inspect","top":-1}"#,
        r#"{"action":"inspect","sort":"cpu"}"#,
        r#"{"action":"inspect","sort":1}"#,
    ] {
        let (_d, r) = dirs();
        put(&r.inbox, "req-20261007-120000.json", body);
        let s = scan_inbox(&r, NOW);
        assert!(s.inspects.is_empty(), "{body} を受け付けた");
        assert_eq!(s.rejected.len(), 1, "{body}");
        assert_eq!(names(&r.error), ["req-20261007-120000.json"], "{body}");
        assert!(!read_json(&r.error.join("req-20261007-120000.json"))["reason"].as_str().unwrap().is_empty());
    }
}

#[test]
fn 再起動と_inspect_が同時にあれば_両方を受け取る() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261007-120000.json", r#"{"action":"inspect"}"#);
    put(&r.inbox, "req-20261007-120001.json", r#"{"action":"restart"}"#);
    let s = scan_inbox(&r, NOW);
    assert!(s.restart);
    assert_eq!(s.inspects.len(), 1);
}

#[test]
fn 結果は_コミットの大きい順に_上位_n_件_読めなかったものは_最後() {
    let v = inspect_result(&sample(), &mem(), 3, InspectSort::Commit);
    assert_eq!(pids(&v), [20, 40, 10]);
    let first = &v["processes"][0];
    assert_eq!(first["commit_bytes"].as_u64(), Some(6 * GB));
    assert_eq!(first["working_set_bytes"].as_u64(), Some(2 * GB));
    assert_eq!(first["process_name"], "big.exe");
    assert_eq!(first["parent_pid"].as_i64(), Some(1));
    assert_eq!(first["started_at"], "2026/10/04 09:05:06.007");
    assert_eq!(v["process_count"].as_u64(), Some(4), "全体の件数");
}

#[test]
fn 結果は_作業セット順にもできる() {
    let v = inspect_result(&sample(), &mem(), 2, InspectSort::WorkingSet);
    assert_eq!(pids(&v), [40, 20]);
}

// 読めなかったプロセスの値は、0 ではなく null（0 は「使っていない」と読まれる）
#[test]
fn 読めなかったプロセスの値は_null() {
    let v = inspect_result(&sample(), &mem(), 10, InspectSort::Commit);
    assert_eq!(pids(&v).last(), Some(&30));
    let last = v["processes"].as_array().unwrap().last().unwrap();
    assert!(last["commit_bytes"].is_null());
    assert!(last["working_set_bytes"].is_null());
}

// 資格情報が入りうる。結果のファイルは、依頼者が読み、資料や会話に貼られうる
#[test]
fn 結果に_コマンドラインも_実行ファイルのパスも含めない() {
    let text = inspect_result(&sample(), &mem(), 10, InspectSort::Commit).to_string();
    assert!(!text.contains("SECRET-VALUE"), "コマンドラインが漏れた");
    assert!(!text.contains("--token"));
    assert!(!text.contains("command_line"));
    assert!(!text.contains("C:/x/"), "実行ファイルのパスが入った");
}

#[test]
fn 結果に_システム全体の値を含める_取れなかった値は_null() {
    let v = inspect_result(&sample(), &mem(), 1, InspectSort::Commit);
    let s = &v["system"];
    assert_eq!(s["phys_total"].as_u64(), Some(32 * GB));
    assert_eq!(s["phys_avail"].as_u64(), Some(7 * GB));
    assert_eq!(s["commit_used"].as_u64(), Some(54 * GB));
    assert_eq!(s["commit_limit"].as_u64(), Some(56 * GB));
    assert_eq!(s["pagefile_used"].as_u64(), Some(GB));
    assert!(s["pagefile_peak"].is_null());
    assert!(s["kernel_paged"].is_null());
}

#[test]
fn 完了すると_comp_に依頼と結果と時刻が書かれ_処理中から消える() {
    let (_d, r) = dirs();
    put(&r.inbox, "req-20261007-120000.json", r#"{"action":"inspect","top":2}"#);
    let s = scan_inbox(&r, NOW);
    let result = inspect_result(&sample(), &mem(), 2, InspectSort::Commit);
    complete_inspect(&r, &s.inspects[0].0, NOW, "0.1.0", &result);
    assert!(names(&r.proc).is_empty(), "処理中に残っている");
    let j = read_json(&r.comp.join("req-20261007-120000.json"));
    assert_eq!(j["status"], "completed");
    assert_eq!(j["version"], "0.1.0");
    assert_eq!(j["completed_at"], "2026/10/04 09:05:06.007");
    assert_eq!(j["request"]["action"], "inspect");
    assert_eq!(j["result"]["processes"].as_array().unwrap().len(), 2);
}

// 調査の途中で終わった（再起動など）依頼は、やり直さない。取った時点の値でないと意味が無いため
#[test]
fn 処理中に残った_inspect_の依頼は_中断として失敗へ移す() {
    let (_d, r) = dirs();
    put(&r.proc, "req-20261007-120000.json", r#"{"action":"inspect"}"#);
    recover_proc(&r, NOW, "0.1.0");
    assert!(names(&r.comp).is_empty());
    assert_eq!(names(&r.error), ["req-20261007-120000.json"]);
}
