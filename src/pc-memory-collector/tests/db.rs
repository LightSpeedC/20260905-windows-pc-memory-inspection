use rust_ai_pc_memory_collector::collect::{ProcessInfo, SystemMemory};
use rust_ai_pc_memory_collector::db::{checkpoint_truncate, insert_snapshot, insert_system_memory, latest_system_memory_ts, open_and_migrate, record_event};
use rust_ai_pc_memory_collector::timeutil::format_jst;
use rusqlite::Connection;

const MB: u64 = 1024 * 1024;

fn proc(pid: u32, start: i64, name: &str, cmd: Option<&str>, cpu_ms: u64) -> ProcessInfo {
    ProcessInfo {
        pid,
        parent_pid: Some(1),
        start_time_ms: start,
        name: name.to_string(),
        exe_path: Some(format!(r"C:\Program Files\{name}")),
        command_line: cmd.map(|s| s.to_string()),
        cpu_total_ms: Some(cpu_ms),
        memory_bytes: Some(100 * MB),
        virtual_bytes: Some(50 * MB),
    }
}

fn open(dir: &std::path::Path) -> Connection {
    open_and_migrate(&dir.join("pc-memory.db"), &dir.join("backup"), 1_000).unwrap()
}

fn count(c: &Connection, table: &str) -> i64 {
    c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0)).unwrap()
}

fn columns(c: &Connection, table: &str) -> Vec<String> {
    c.prepare(&format!("SELECT name FROM pragma_table_info('{table}') ORDER BY cid"))
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect()
}

fn mem() -> SystemMemory {
    SystemMemory {
        phys_total: 1000,
        phys_avail: 500,
        swap_total: None,
        swap_used: None,
        commit_limit: None,
        commit_used: None,
        pagefile_used: None,
        pagefile_peak: None,
        kernel_paged: None,
        kernel_nonpaged: None,
        system_cache: None,
    }
}

// 版 2 で足した列。版 1 の swap_used は commit_used − phys_total の計算値で、実際のページファイルの使用ではない（i261007-01）
#[test]
fn 版_2_で_ページファイルの実使用と_カーネルのプールとキャッシュの列が増える() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    assert_eq!(count(&c, "versions"), 2);
    assert_eq!(
        columns(&c, "system_memory"),
        [
            "measured_at", "phys_total", "phys_avail", "swap_total", "swap_used", "commit_limit", "commit_used", "pagefile_used", "pagefile_peak",
            "kernel_paged", "kernel_nonpaged", "system_cache"
        ]
    );
}

#[test]
fn 版_2_の列を書いて読める_取れなかった値は_null() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    let mut m = mem();
    m.pagefile_used = Some(2 * 1024 * MB);
    m.kernel_nonpaged = Some(3 * MB);
    insert_system_memory(&c, 60_000, &m).unwrap();
    let row: (Option<i64>, Option<i64>, Option<i64>) = c
        .query_row("SELECT pagefile_used, pagefile_peak, kernel_nonpaged FROM system_memory", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .unwrap();
    assert_eq!(row, (Some(2 * 1024 * MB as i64), None, Some(3 * MB as i64)));
}

// 実際に動いている DB は版 1 のまま。行を失わず、控え（zip）を取って、版 2 へ上がる
#[test]
fn 版_1_の_db_を開くと_行を残したまま_版_2_へ上がり_控えが取られる() {
    use rust_ai_pc_memory_collector::migrate::{embedded_versions, migrate};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pc-memory.db");
    {
        let mut c = Connection::open(&path).unwrap();
        migrate(&mut c, &embedded_versions()[..1], None, 1_000).unwrap();
        c.execute("INSERT INTO system_memory (measured_at, phys_total, phys_avail) VALUES (?1, 1, 1)", [format_jst(60_000)]).unwrap();
    }
    let c = open(dir.path());
    assert_eq!(count(&c, "system_memory"), 1, "行が失われた");
    let n: Option<i64> = c.query_row("SELECT pagefile_used FROM system_memory", [], |r| r.get(0)).unwrap();
    assert_eq!(n, None, "過去の行の新しい列は NULL のまま");
    assert_eq!(count(&c, "versions"), 2);
    let zips: Vec<String> = std::fs::read_dir(dir.path().join("backup")).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    assert!(zips.iter().any(|n| n.starts_with("pre-ver-000001-")), "上げる前の控えが無い: {zips:?}");
}

// 実機では、5 つとも取れる（取れないなら NULL に倒れて、このテストが気づかせる）
#[cfg(windows)]
#[test]
fn windows_では_ページファイルとカーネルのプールとキャッシュを取れる() {
    use rust_ai_pc_memory_collector::collect::{Source, SysinfoSource};
    let m = SysinfoSource::new().system_memory();
    let used = m.pagefile_used.expect("pagefile_used が取れない");
    let peak = m.pagefile_peak.expect("pagefile_peak が取れない");
    assert!(peak >= used, "ピーク {peak} が使用 {used} より小さい");
    assert!(m.kernel_paged.expect("kernel_paged") > 0);
    assert!(m.kernel_nonpaged.expect("kernel_nonpaged") > 0);
    assert!(m.system_cache.expect("system_cache") > 0);
    assert!(m.pagefile_used.unwrap() <= m.swap_total.unwrap_or(u64::MAX), "使用がページファイルの合計を超えている");
}

#[test]
fn 初回の起動で_テーブルがそろい_版が記録される() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    for t in ["system_memory", "process_snapshot", "process_sample", "command_line", "collector_event", "versions"] {
        assert!(count(&c, t) >= 0, "{t} が無い");
    }
    assert_eq!(count(&c, "versions"), 2);
}

#[test]
fn もう一度開いても_版は増えない() {
    let dir = tempfile::tempdir().unwrap();
    drop(open(dir.path()));
    let c = open(dir.path());
    assert_eq!(count(&c, "versions"), 2);
}

// 命名の決まり（ai-chat-lite に合わせる）: 主キーは <テーブル>_id、外部キーは参照先の主キーと同じ名前、日時は _at、略語を使わない
#[test]
fn 列名は_命名の決まりどおり() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    assert_eq!(
        columns(&c, "system_memory"),
        [
            "measured_at", "phys_total", "phys_avail", "swap_total", "swap_used", "commit_limit", "commit_used", "pagefile_used", "pagefile_peak",
            "kernel_paged", "kernel_nonpaged", "system_cache"
        ]
    );
    assert_eq!(
        columns(&c, "process_snapshot"),
        ["process_snapshot_id", "measured_at", "logical_cpu_count", "process_count", "command_line_unreadable_count", "is_admin"]
    );
    assert_eq!(columns(&c, "command_line"), ["command_line_id", "command_line_body"]);
    assert_eq!(
        columns(&c, "process_sample"),
        [
            "process_snapshot_id", "pid", "started_at", "parent_pid", "process_name", "exe_path", "command_line_id", "cpu_total_ms",
            "cpu_percent", "memory_bytes", "virtual_bytes"
        ]
    );
    assert_eq!(columns(&c, "collector_event"), ["collector_event_id", "occurred_at", "event_kind", "event_message"]);
    assert_eq!(columns(&c, "versions"), ["version_seq", "applied_at", "script_name", "sql_sha256"]);
}

#[test]
fn 索引の名前は_テーブル名_ix_列名() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    let names: Vec<String> = c
        .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(names, ["collector_event_ix_occurred_at", "process_sample_ix_pid_started_at", "process_snapshot_ix_measured_at"]);
}

#[test]
fn システムのメモリを_1_行書き_最新の時刻を読める() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    assert_eq!(latest_system_memory_ts(&c).unwrap(), None);
    let m = SystemMemory { phys_total: 32 * 1024 * MB, phys_avail: 10 * 1024 * MB, swap_total: Some(18 * 1024 * MB), swap_used: Some(MB), commit_limit: None, commit_used: None, ..mem() };
    insert_system_memory(&c, 60_000, &m).unwrap();
    insert_system_memory(&c, 120_000, &m).unwrap();
    assert_eq!(latest_system_memory_ts(&c).unwrap(), Some(120_000));
    // OS に無い値は NULL のまま
    let n: Option<i64> = c.query_row("SELECT commit_limit FROM system_memory WHERE measured_at = ?1", [format_jst(60_000)], |r| r.get(0)).unwrap();
    assert_eq!(n, None);
}

// DB を直接見ても読め、辞書順がそのまま時系列順になる。ai-chat-lite の sent_at と同じ形
#[test]
fn 日時は_jst_の_23_文字で書く() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    insert_system_memory(&c, 1_791_072_306_007, &mem()).unwrap();
    let at: String = c.query_row("SELECT measured_at FROM system_memory", [], |r| r.get(0)).unwrap();
    assert_eq!(at, "2026/10/04 09:05:06.007");
}

#[test]
fn 日時の列に_23_文字でない値は入れられない() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    let e = c.execute("INSERT INTO system_memory (measured_at, phys_total, phys_avail) VALUES ('2026-10-04', 1, 1)", []);
    assert!(e.is_err(), "CHECK (length = 23) が効いていない");
    let e = c.execute("INSERT INTO collector_event (occurred_at, event_kind, event_message) VALUES ('x', 'start', 'm')", []);
    assert!(e.is_err());
}

#[test]
fn スナップショットは_プロセスごとに_1_行を書く() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    let ps = [proc(10, 1_000, "a.exe", Some("a.exe -x"), 100), proc(20, 2_000, "b.exe", Some("b.exe"), 200)];
    let id = insert_snapshot(&mut c, 3_600_000, 8, false, &ps).unwrap();
    assert_eq!(count(&c, "process_sample"), 2);
    let n: i64 = c.query_row("SELECT process_count FROM process_snapshot WHERE process_snapshot_id = ?1", [id], |r| r.get(0)).unwrap();
    assert_eq!(n, 2);
}

#[test]
fn プロセスの起動時刻と取得時刻は_jst_の_23_文字で書く() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 1_791_072_306_007, 8, false, &[proc(10, 1_791_000_000_000, "a.exe", Some("a"), 1)]).unwrap();
    let measured: String = c.query_row("SELECT measured_at FROM process_snapshot", [], |r| r.get(0)).unwrap();
    let started: String = c.query_row("SELECT started_at FROM process_sample", [], |r| r.get(0)).unwrap();
    assert_eq!(measured, "2026/10/04 09:05:06.007");
    assert_eq!(started, format_jst(1_791_000_000_000));
}

// どの権限で書いたかを、あとから区別できるようにする（権限で、読めなかったプロセスの数が大きく変わる）
#[test]
fn 管理者権限で書いたかを_スナップショットに残す() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 3_600_000, 8, true, &[proc(10, 1_000, "a.exe", Some("a"), 1)]).unwrap();
    insert_snapshot(&mut c, 7_200_000, 8, false, &[proc(10, 1_000, "a.exe", Some("a"), 2)]).unwrap();
    let v: Vec<i64> = c
        .prepare("SELECT is_admin FROM process_snapshot ORDER BY process_snapshot_id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert_eq!(v, [1, 0]);
}

#[test]
fn is_admin_には_0_と_1_以外を入れられない() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    let e = c.execute(
        "INSERT INTO process_snapshot (measured_at, logical_cpu_count, process_count, command_line_unreadable_count, is_admin) VALUES ('2026/10/04 09:05:06.007', 8, 1, 0, 2)",
        [],
    );
    assert!(e.is_err(), "CHECK (is_admin IN (0, 1)) が効いていない");
}

#[test]
fn 同じコマンドラインは_重複を持たない() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    let ps = [proc(10, 1_000, "a.exe", Some("a.exe -x"), 100), proc(20, 2_000, "a.exe", Some("a.exe -x"), 200)];
    insert_snapshot(&mut c, 3_600_000, 8, false, &ps).unwrap();
    insert_snapshot(&mut c, 7_200_000, 8, false, &ps).unwrap();
    assert_eq!(count(&c, "command_line"), 1);
    assert_eq!(count(&c, "process_sample"), 4);
}

#[test]
fn パスとコマンドラインのユーザープロファイルは_チルダにして書く() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    let mut p = proc(10, 1_000, "a.exe", Some(r"C:\Users\alice\a.exe --dir=C:\Users\bob"), 100);
    p.exe_path = Some(r"C:\Users\alice\a.exe".to_string());
    insert_snapshot(&mut c, 3_600_000, 8, false, &[p]).unwrap();
    let exe: String = c.query_row("SELECT exe_path FROM process_sample", [], |r| r.get(0)).unwrap();
    let cmd: String = c.query_row("SELECT command_line_body FROM command_line", [], |r| r.get(0)).unwrap();
    assert_eq!(exe, r"~\a.exe");
    assert_eq!(cmd, r"~\a.exe --dir=~");
}

#[test]
fn コマンドラインが取れなかったプロセスは_null_で_件数をスナップショットに残す() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    let ps = [proc(10, 1_000, "a.exe", None, 100), proc(20, 2_000, "b.exe", Some("b.exe"), 200)];
    let id = insert_snapshot(&mut c, 3_600_000, 8, false, &ps).unwrap();
    let unreadable: i64 =
        c.query_row("SELECT command_line_unreadable_count FROM process_snapshot WHERE process_snapshot_id = ?1", [id], |r| r.get(0)).unwrap();
    assert_eq!(unreadable, 1);
    let nulls: i64 = c.query_row("SELECT COUNT(*) FROM process_sample WHERE command_line_id IS NULL", [], |r| r.get(0)).unwrap();
    assert_eq!(nulls, 1);
}

#[test]
fn cpu_使用率は_前回のスナップショットの同じプロセスとの差で出す() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    // 1 回目は前回が無いので NULL
    insert_snapshot(&mut c, 3_600_000, 8, false, &[proc(10, 1_000, "a.exe", Some("a"), 1_000)]).unwrap();
    let first: Option<f64> = c.query_row("SELECT cpu_percent FROM process_sample", [], |r| r.get(0)).unwrap();
    assert_eq!(first, None);
    // 2 回目: 1 時間で CPU 累計が 288,000 ms 増えた → 288000 / 3600000 / 8 * 100 = 1.0
    insert_snapshot(&mut c, 7_200_000, 8, false, &[proc(10, 1_000, "a.exe", Some("a"), 289_000), proc(30, 5_000, "new.exe", Some("n"), 10)]).unwrap();
    let rows: Vec<(i64, Option<f64>)> = c
        .prepare("SELECT pid, cpu_percent FROM process_sample WHERE process_snapshot_id = 2 ORDER BY pid")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .map(|r| r.unwrap())
        .collect();
    assert!((rows[0].1.unwrap() - 1.0).abs() < 1e-9, "{rows:?}");
    assert_eq!(rows[1].1, None, "新しく現れたプロセスは NULL");
}

#[test]
fn pid_が同じでも_起動時刻が違えば_別のプロセスとして扱う() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 3_600_000, 8, false, &[proc(10, 1_000, "a.exe", Some("a"), 1_000)]).unwrap();
    insert_snapshot(&mut c, 7_200_000, 8, false, &[proc(10, 9_999, "a.exe", Some("a"), 500_000)]).unwrap();
    let v: Option<f64> = c.query_row("SELECT cpu_percent FROM process_sample WHERE process_snapshot_id = 2", [], |r| r.get(0)).unwrap();
    assert_eq!(v, None);
}

// 権限が無いプロセスは、メモリも CPU 累計も 0 で返ってくる。0 で書くと「使っていない」「暇だった」と読めてしまい、平均を狂わせる。
// 取れなかった値は NULL にして、集計（AVG・SUM）から外す（実測: 非管理者では 568 件中 261 件が該当）
fn unreadable(pid: u32, start: i64) -> ProcessInfo {
    let mut p = proc(pid, start, "system.exe", None, 0);
    p.exe_path = None;
    p.cpu_total_ms = None;
    p.memory_bytes = None;
    p.virtual_bytes = None;
    p
}

#[test]
fn 読めなかったプロセスは_メモリと_cpu_累計と_仮想メモリを_null_で書く() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 3_600_000, 8, false, &[unreadable(4, 1_000)]).unwrap();
    let r: (Option<i64>, Option<i64>, Option<i64>) =
        c.query_row("SELECT memory_bytes, cpu_total_ms, virtual_bytes FROM process_sample", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
    assert_eq!(r, (None, None, None));
}

#[test]
fn 読めなかったプロセスの_cpu_使用率は_0_ではなく_null() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 3_600_000, 8, false, &[unreadable(4, 1_000)]).unwrap();
    insert_snapshot(&mut c, 7_200_000, 8, false, &[unreadable(4, 1_000)]).unwrap();
    let v: Option<f64> = c.query_row("SELECT cpu_percent FROM process_sample WHERE process_snapshot_id = 2", [], |r| r.get(0)).unwrap();
    assert_eq!(v, None);
}

#[test]
fn 前回が読めなかったプロセスは_今回読めても_cpu_使用率を_null_にする() {
    let dir = tempfile::tempdir().unwrap();
    let mut c = open(dir.path());
    insert_snapshot(&mut c, 3_600_000, 8, false, &[unreadable(10, 1_000)]).unwrap();
    insert_snapshot(&mut c, 7_200_000, 8, false, &[proc(10, 1_000, "a.exe", Some("a"), 500_000)]).unwrap();
    let v: Option<f64> = c.query_row("SELECT cpu_percent FROM process_sample WHERE process_snapshot_id = 2", [], |r| r.get(0)).unwrap();
    assert_eq!(v, None, "前回の累計が無いのに差を出すと、全期間の CPU を 1 時間の使用率にしてしまう");
}

// WAL（-wal）は、開いたままの読み取りがあると統合が進まず、大きくなり続ける。いったん大きくなると、そのままの大きさで残る。
// 上限を決め、毎日の掃除（TRUNCATE）で縮める
#[test]
fn wal_の大きさの上限を_64_mb_に決めている() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    let limit: i64 = c.query_row("PRAGMA journal_size_limit", [], |r| r.get(0)).unwrap();
    assert_eq!(limit, 64 * 1024 * 1024);
}

fn wal_size(dir: &std::path::Path) -> u64 {
    std::fs::metadata(dir.join("pc-memory.db-wal")).map(|m| m.len()).unwrap_or(0)
}

#[test]
fn 毎日の掃除で_wal_が空になり_行は失われない() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    for i in 0..50 {
        insert_system_memory(&c, 60_000 * (i + 1), &mem()).unwrap();
    }
    assert!(wal_size(dir.path()) > 0, "掃除の前は、WAL に書き込みが残っている（この前提が崩れたら、テストの意味が無い）");
    checkpoint_truncate(&c).unwrap();
    assert_eq!(wal_size(dir.path()), 0, "掃除のあとも WAL が残っている");
    assert_eq!(count(&c, "system_memory"), 50, "掃除で行が失われた");
}

#[test]
fn 読み取りが開いたままで掃除できなくても_エラーを返すだけで_行は失われない() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    insert_system_memory(&c, 60_000, &mem()).unwrap();
    // 別の接続が、読み取りを開いたままにする（閲覧ツールを放置した状態）
    let reader = Connection::open(dir.path().join("pc-memory.db")).unwrap();
    reader.execute_batch("BEGIN; SELECT COUNT(*) FROM system_memory;").unwrap();
    insert_system_memory(&c, 120_000, &mem()).unwrap();
    let e = checkpoint_truncate(&c);
    assert!(e.is_err(), "読み取りが開いたままでも、掃除できてしまった");
    assert_eq!(count(&c, "system_memory"), 2);
    reader.execute_batch("COMMIT;").unwrap();
    assert!(checkpoint_truncate(&c).is_ok(), "読み取りを閉じたら、掃除できる");
}

#[test]
fn イベントを書ける() {
    let dir = tempfile::tempdir().unwrap();
    let c = open(dir.path());
    record_event(&c, 1_000, "start", "開始").unwrap();
    let k: String = c.query_row("SELECT event_kind FROM collector_event", [], |r| r.get(0)).unwrap();
    assert_eq!(k, "start");
    let at: String = c.query_row("SELECT occurred_at FROM collector_event", [], |r| r.get(0)).unwrap();
    assert_eq!(at, format_jst(1_000));
}
