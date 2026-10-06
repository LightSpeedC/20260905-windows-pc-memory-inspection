use rust_ai_pc_memory_collector::migrate::{migrate, Version};
use rusqlite::Connection;

fn v(seq: u32, files: &[(&str, &str)]) -> Version {
    Version {
        seq,
        name: format!("ver_{seq:06}"),
        files: files.iter().map(|(n, s)| (n.to_string(), s.to_string())).collect(),
    }
}

fn table_exists(c: &Connection, name: &str) -> bool {
    c.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1", [name], |r| r.get::<_, i64>(0))
        .unwrap()
        > 0
}

fn versions_count(c: &Connection) -> i64 {
    c.query_row("SELECT COUNT(*) FROM versions", [], |r| r.get(0)).unwrap()
}

#[test]
fn 空の_db_には_版_1_から順に当てる() {
    let mut c = Connection::open_in_memory().unwrap();
    let vs = vec![
        v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")]),
        v(2, &[("001.sql", "CREATE TABLE b (y INTEGER);")]),
    ];
    let r = migrate(&mut c, &vs, None, 1_000).unwrap();
    assert_eq!((r.from, r.to), (0, 2));
    assert!(table_exists(&c, "a") && table_exists(&c, "b"));
    assert_eq!(versions_count(&c), 2);
}

// 当てた時刻は、他の日時の列と同じ JST の 23 文字（ai-chat-lite の versions に合わせる）
#[test]
fn 当てた時刻は_jst_の_23_文字で_スクリプト名は_script_name_に残す() {
    let mut c = Connection::open_in_memory().unwrap();
    migrate(&mut c, &[v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])], None, 1_791_072_306_007).unwrap();
    let (at, name): (String, String) =
        c.query_row("SELECT applied_at, script_name FROM versions", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!(at, "2026/10/04 09:05:06.007");
    assert_eq!(name, "001.sql");
}

#[test]
fn 当て済みの版は_もう一度当てない() {
    let mut c = Connection::open_in_memory().unwrap();
    let vs = vec![v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])];
    migrate(&mut c, &vs, None, 1_000).unwrap();
    let r = migrate(&mut c, &vs, None, 2_000).unwrap();
    assert_eq!((r.from, r.to), (1, 1));
    assert!(r.applied.is_empty());
}

#[test]
fn 版を足すと_足りない分だけを当てる() {
    let mut c = Connection::open_in_memory().unwrap();
    let mut vs = vec![v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])];
    migrate(&mut c, &vs, None, 1_000).unwrap();
    vs.push(v(2, &[("001.sql", "CREATE TABLE b (y INTEGER);")]));
    let r = migrate(&mut c, &vs, None, 2_000).unwrap();
    assert_eq!(r.applied, vec!["ver_000002".to_string()]);
    assert!(table_exists(&c, "b"));
}

#[test]
fn 当て済みの_sql_が書き換えられていたら止める() {
    let mut c = Connection::open_in_memory().unwrap();
    migrate(&mut c, &[v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])], None, 1_000).unwrap();
    let edited = [v(1, &[("001.sql", "CREATE TABLE a (x INTEGER, z INTEGER);")])];
    let e = migrate(&mut c, &edited, None, 2_000).unwrap_err();
    assert!(e.contains("書き換え"), "{e}");
}

#[test]
fn 版の番号が飛んでいたら止める() {
    let mut c = Connection::open_in_memory().unwrap();
    let vs = [v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")]), v(3, &[("001.sql", "CREATE TABLE c (z INTEGER);")])];
    let e = migrate(&mut c, &vs, None, 1_000).unwrap_err();
    assert!(e.contains("連続"), "{e}");
}

#[test]
fn 版の当て方に失敗したら_その版だけを巻き戻す() {
    let mut c = Connection::open_in_memory().unwrap();
    let vs = vec![
        v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")]),
        // 2 つ目の文が失敗する。1 つ目の文（テーブル b）も残してはいけない
        v(2, &[("001.sql", "CREATE TABLE b (y INTEGER); INSERT INTO no_such_table VALUES (1);")]),
    ];
    let e = migrate(&mut c, &vs, None, 1_000).unwrap_err();
    assert!(e.contains("ver_000002"), "{e}");
    assert!(table_exists(&c, "a"), "版 1 は当たったまま");
    assert!(!table_exists(&c, "b"), "失敗した版の途中の変更が残っている");
    assert_eq!(versions_count(&c), 1);
}

#[test]
fn versions_が無いのに_すでにテーブルがある_db_は_版_1_を当てずに記録する() {
    let mut c = Connection::open_in_memory().unwrap();
    c.execute_batch("CREATE TABLE a (x INTEGER); INSERT INTO a VALUES (7);").unwrap();
    // 当て直すと「テーブルがもうある」で失敗する。記録だけして、中身は残す
    let vs = [v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])];
    migrate(&mut c, &vs, None, 1_000).unwrap();
    let n: i64 = c.query_row("SELECT x FROM a", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 7);
    assert_eq!(versions_count(&c), 1);
}

#[test]
fn 版を上げる前に_使用中の_db_の控えを_zip_で取る() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("t.db");
    let backup = dir.path().join("backup");
    let mut c = Connection::open(&db_path).unwrap();
    migrate(&mut c, &[v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])], None, 1_000).unwrap();
    c.execute("INSERT INTO a VALUES (1)", []).unwrap();

    let vs = [v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")]), v(2, &[("001.sql", "CREATE TABLE b (y INTEGER);")])];
    migrate(&mut c, &vs, Some(&backup), 1_791_072_306_007).unwrap();

    let names: Vec<String> = std::fs::read_dir(&backup).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names, vec!["pre-ver-000001-20261004090506.zip".to_string()]);
}

#[test]
fn 空の_db_には_控えを取らない() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    let mut c = Connection::open(dir.path().join("t.db")).unwrap();
    migrate(&mut c, &[v(1, &[("001.sql", "CREATE TABLE a (x INTEGER);")])], Some(&backup), 1_000).unwrap();
    assert!(!backup.exists() || std::fs::read_dir(&backup).unwrap().count() == 0);
}

#[test]
fn 版の_sql_が空のときは止める() {
    let mut c = Connection::open_in_memory().unwrap();
    let e = migrate(&mut c, &[v(1, &[])], None, 1_000).unwrap_err();
    assert!(e.contains("sql"), "{e}");
}
