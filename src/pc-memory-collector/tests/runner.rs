use rust_ai_pc_memory_collector::collect::{ProcessInfo, Source, SystemMemory};
use rust_ai_pc_memory_collector::config::Config;
use rust_ai_pc_memory_collector::db::open_and_migrate;
use rust_ai_pc_memory_collector::runner::Collector;
use rust_ai_pc_memory_collector::timeutil::jst_to_ms;
use rusqlite::Connection;

struct Fake {
    is_admin: bool,
}

impl Source for Fake {
    fn is_admin(&mut self) -> bool {
        self.is_admin
    }
    fn system_memory(&mut self) -> SystemMemory {
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
    fn processes(&mut self) -> (u32, Vec<ProcessInfo>) {
        let p = ProcessInfo {
            pid: 1,
            parent_pid: None,
            start_time_ms: 1,
            name: "a.exe".into(),
            exe_path: None,
            command_line: Some("a".into()),
            cpu_total_ms: Some(1),
            memory_bytes: Some(1),
            virtual_bytes: None,
        };
        (4, vec![p])
    }
}

fn setup_as(is_admin: bool) -> (tempfile::TempDir, Collector<Fake>) {
    let dir = tempfile::tempdir().unwrap();
    let cfg = Config::new(dir.path().to_path_buf());
    let conn = open_and_migrate(&cfg.db_path, &cfg.backup_dir, 1_000).unwrap();
    (dir, Collector::new(conn, cfg, Fake { is_admin }))
}

fn setup() -> (tempfile::TempDir, Collector<Fake>) {
    setup_as(false)
}

fn setup_with(memory_sec: i64, process_sec: i64) -> (tempfile::TempDir, Collector<Fake>) {
    let dir = tempfile::tempdir().unwrap();
    let mut cfg = Config::new(dir.path().to_path_buf());
    cfg.memory_interval_ms = memory_sec * 1_000;
    cfg.process_interval_ms = process_sec * 1_000;
    let conn = open_and_migrate(&cfg.db_path, &cfg.backup_dir, 1_000).unwrap();
    (dir, Collector::new(conn, cfg, Fake { is_admin: false }))
}

fn count(c: &Connection, sql: &str) -> i64 {
    c.query_row(sql, [], |r| r.get(0)).unwrap()
}

fn t(d: u32, h: u32, m: u32, s: u32) -> i64 {
    jst_to_ms(2026, 10, d, h, m, s)
}

#[test]
fn 最初の周期で_メモリとプロセスの両方を書く() {
    let (_d, mut c) = setup();
    c.tick(t(4, 9, 0, 5));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 1);
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 1);
}

#[test]
fn 同じ時間の中では_プロセスのスナップショットを増やさない() {
    let (_d, mut c) = setup();
    c.tick(t(4, 9, 0, 5));
    c.tick(t(4, 9, 1, 0));
    c.tick(t(4, 9, 59, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 3);
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 1);
}

#[test]
fn 時間が変わると_プロセスのスナップショットを書く() {
    let (_d, mut c) = setup();
    c.tick(t(4, 9, 59, 0));
    c.tick(t(4, 10, 0, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 2);
}

#[test]
fn スリープ明けで何時間も抜けても_さかのぼって埋めず_現在の_1_件だけを書く() {
    let (_d, mut c) = setup();
    c.tick(t(4, 9, 0, 0));
    c.tick(t(4, 15, 30, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 2);
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 2);
}

#[test]
fn 毎日_23_59_にバックアップを作り_同じ分の再実行では作り直さない() {
    let (d, mut c) = setup();
    c.tick(t(4, 23, 58, 0));
    assert!(!d.path().join("_backup").join("pc-memory-20261004.zip").exists(), "23:59 の前に作っている");
    c.tick(t(4, 23, 59, 0));
    assert!(d.path().join("_backup").join("pc-memory-20261004.zip").exists());
    c.tick(t(4, 23, 59, 30));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'backup'"), 1);
}

#[test]
fn バックアップの時刻に動いていなかったときは_次の周期で前日の分を作る() {
    let (d, mut c) = setup();
    c.tick(t(4, 23, 0, 0));
    // PC がスリープしていて、23:59 を逃した。翌日 0:05 に復帰
    c.tick(t(5, 0, 5, 0));
    assert!(d.path().join("_backup").join("pc-memory-20261004.zip").exists(), "前日の名前で作る");
}

#[test]
fn 開始と停止をイベントに残す() {
    let (_d, mut c) = setup();
    c.record_start(t(4, 9, 0, 0));
    c.record_stop(t(4, 9, 5, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'start'"), 1);
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'stop'"), 1);
}

// 起動した時刻からの間隔ではなく、時計の区切り（毎分 hh:mm:00・毎時 hh:00:00）に書く。
// 起動が 00:12:34 でも、10 秒間隔なら最初の実行は 00:12:40（起動の時刻に引きずられず、複数の PC・日をまたいで並べやすい）
#[test]
fn 次に動く時刻は_起動からの間隔ではなく_時計の区切り() {
    let (_d, c) = setup_with(10, 10);
    assert_eq!(c.next_wake(t(4, 0, 12, 34)), t(4, 0, 12, 40));
    assert_eq!(c.next_wake(t(4, 0, 12, 40)), t(4, 0, 12, 50), "区切りちょうどなら、次の区切り");
    let (_d, c) = setup();
    assert_eq!(c.next_wake(t(4, 0, 12, 34)), t(4, 0, 13, 0), "既定は毎分");
}

#[test]
fn プロセスの間隔のほうが短ければ_そちらの区切りでも動く() {
    let (_d, c) = setup_with(60, 10);
    assert_eq!(c.next_wake(t(4, 0, 12, 34)), t(4, 0, 12, 40));
}

#[test]
fn 起動の途中の区切りは書かず_次の区切りから書く() {
    let (_d, mut c) = setup();
    c.align_to_boundaries(t(4, 0, 12, 34));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 0, "起動の直後は書かない");
    c.tick(t(4, 0, 13, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 1, "次の毎分の区切りで書く");
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 0, "毎時の区切りが来るまでは、プロセスを書かない");
    c.tick(t(4, 0, 59, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 0);
    c.tick(t(4, 1, 0, 0));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM process_snapshot"), 1, "毎時の区切りで書く");
}

#[test]
fn 同じ区切りの中では_メモリを重ねて書かない() {
    let (_d, mut c) = setup();
    c.tick(t(4, 9, 1, 0));
    c.tick(t(4, 9, 1, 30));
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM system_memory"), 1);
}

// 毎日のバックアップの前に WAL を掃除する。読み取りが開いたままで掃除できなくても、バックアップも収集も止めず、イベントに残す
#[test]
fn 掃除できなくても_バックアップは作り_エラーのイベントに残す() {
    let (d, mut c) = setup();
    c.tick(t(4, 23, 58, 0));
    let reader = rusqlite::Connection::open(d.path().join("_data").join("pc-memory.db")).unwrap();
    reader.execute_batch("BEGIN; SELECT COUNT(*) FROM system_memory;").unwrap();
    c.tick(t(4, 23, 59, 0));
    assert!(d.path().join("_backup").join("pc-memory-20261004.zip").exists(), "掃除に失敗してもバックアップは作る");
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'error' AND event_message LIKE '%統合%'"), 1);
    reader.execute_batch("COMMIT;").unwrap();
}

#[test]
fn バックアップの前に_wal_を掃除する() {
    let (d, mut c) = setup();
    c.tick(t(4, 23, 58, 0));
    c.tick(t(4, 23, 59, 0));
    let wal = d.path().join("_data").join("pc-memory.db-wal");
    let size = std::fs::metadata(&wal).map(|m| m.len()).unwrap_or(0);
    // バックアップのあとにイベントを 1 件書くため、完全に 0 とは限らない。掃除されていれば、数ページ（数十 KB）に収まる
    assert!(size < 32 * 1024, "WAL が掃除されていない（{size} byte）");
}

#[test]
fn 再起動の依頼を受け取ると_イベントに残し_再起動を求める() {
    let (d, mut c) = setup();
    c.ensure_request_dirs(t(4, 9, 0, 0));
    let inbox = d.path().join("_data").join("request").join("inbox");
    std::fs::write(inbox.join("req-20261006-233700.json"), r#"{"action":"restart"}"#).unwrap();
    assert!(c.handle_requests(t(4, 9, 0, 0)), "再起動を求めない");
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'request'"), 1);
}

#[test]
fn 起動時に_処理中に残った再起動の依頼を完了にし_イベントに残す() {
    let (d, mut c) = setup();
    c.ensure_request_dirs(t(4, 9, 0, 0));
    let root = d.path().join("_data").join("request");
    std::fs::write(root.join("proc").join("req-20261006-233700.json"), r#"{"action":"restart"}"#).unwrap();
    c.recover_requests(t(4, 9, 0, 0));
    assert!(root.join("comp").join("req-20261006-233700.json").exists());
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'request'"), 1);
}

// 収集が、依頼の時点のプロセスの一覧を取って、結果を書く。収集は止まらない（再起動を求めない）
#[test]
fn inspect_の依頼を受け取ると_結果を_comp_に書き_イベントに残し_再起動は求めない() {
    let (d, mut c) = setup();
    c.ensure_request_dirs(t(4, 9, 0, 0));
    let root = d.path().join("_data").join("request");
    std::fs::write(root.join("inbox").join("req-20261007-120000.json"), r#"{"action":"inspect","top":5}"#).unwrap();
    assert!(!c.handle_requests(t(4, 9, 0, 0)), "inspect で再起動を求めた");
    let text = std::fs::read_to_string(root.join("comp").join("req-20261007-120000.json")).expect("comp に結果が無い");
    let j: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(j["result"]["processes"].as_array().unwrap().len(), 1);
    assert_eq!(j["result"]["system"]["phys_total"].as_u64(), Some(1000));
    assert!(!text.contains("command_line"));
    assert_eq!(std::fs::read_dir(root.join("proc")).unwrap().count(), 0, "処理中に残っている");
    assert_eq!(count(c.conn(), "SELECT COUNT(*) FROM collector_event WHERE event_kind = 'request'"), 1);
}

fn start_message(c: &Collector<Fake>) -> String {
    c.conn().query_row("SELECT event_message FROM collector_event WHERE event_kind = 'start'", [], |r| r.get(0)).unwrap()
}

#[test]
fn 開始のイベントに_管理者権限の有無を書く() {
    let (_d, mut admin) = setup_as(true);
    admin.record_start(t(4, 9, 0, 0));
    assert!(start_message(&admin).contains("管理者権限あり"), "{}", start_message(&admin));
    let (_d, mut user) = setup_as(false);
    user.record_start(t(4, 9, 0, 0));
    assert!(start_message(&user).contains("管理者権限なし"), "{}", start_message(&user));
}

#[test]
fn スナップショットに_動いている権限を書く() {
    for (is_admin, expected) in [(true, 1), (false, 0)] {
        let (_d, mut c) = setup_as(is_admin);
        c.tick(t(4, 9, 0, 5));
        assert_eq!(count(c.conn(), "SELECT is_admin FROM process_snapshot"), expected);
    }
}
