use rust_ai_pc_memory_collector::backup::{backup_file_name, prune, run_backup};
use rust_ai_pc_memory_collector::collect::SystemMemory;
use rust_ai_pc_memory_collector::db::{insert_system_memory, open_and_migrate};
use rust_ai_pc_memory_collector::timeutil::jst_to_ms;
use std::io::Read;

fn names(dir: &std::path::Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

fn mem() -> SystemMemory {
    SystemMemory { phys_total: 1, phys_avail: 1, swap_total: None, swap_used: None, commit_limit: None, commit_used: None }
}

#[test]
fn バックアップのファイル名は_スロットの_jst_の日付() {
    assert_eq!(backup_file_name(jst_to_ms(2026, 10, 4, 23, 59, 0)), "pc-memory-20261004.zip");
}

#[test]
fn 稼働中の_db_から_整合した_zip_を作る() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    let c = open_and_migrate(&dir.path().join("pc-memory.db"), &backup, 1_000).unwrap();
    insert_system_memory(&c, 60_000, &mem()).unwrap();

    let zip_path = run_backup(&c, &backup, jst_to_ms(2026, 10, 4, 23, 59, 0), 100).unwrap();
    assert_eq!(zip_path.file_name().unwrap().to_string_lossy(), "pc-memory-20261004.zip");

    // zip の中の db を取り出して開き、検査と中身を確かめる
    let mut z = zip::ZipArchive::new(std::fs::File::open(&zip_path).unwrap()).unwrap();
    assert_eq!(z.len(), 1);
    let mut entry = z.by_index(0).unwrap();
    assert_eq!(entry.name(), "pc-memory.db");
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).unwrap();
    let extracted = dir.path().join("extracted.db");
    std::fs::write(&extracted, &bytes).unwrap();
    let x = rusqlite::Connection::open(&extracted).unwrap();
    let ok: String = x.query_row("PRAGMA integrity_check", [], |r| r.get(0)).unwrap();
    assert_eq!(ok, "ok");
    let n: i64 = x.query_row("SELECT COUNT(*) FROM system_memory", [], |r| r.get(0)).unwrap();
    assert_eq!(n, 1);
}

#[test]
fn 作業用のファイルを_バックアップの置き場に残さない() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    let c = open_and_migrate(&dir.path().join("pc-memory.db"), &backup, 1_000).unwrap();
    run_backup(&c, &backup, jst_to_ms(2026, 10, 4, 23, 59, 0), 100).unwrap();
    assert_eq!(names(&backup), vec!["pc-memory-20261004.zip".to_string()]);
}

#[test]
fn 同じ日のバックアップは_作り直して_置き換える() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    let c = open_and_migrate(&dir.path().join("pc-memory.db"), &backup, 1_000).unwrap();
    let slot = jst_to_ms(2026, 10, 4, 23, 59, 0);
    run_backup(&c, &backup, slot, 100).unwrap();
    insert_system_memory(&c, 60_000, &mem()).unwrap();
    run_backup(&c, &backup, slot, 100).unwrap();
    assert_eq!(names(&backup), vec!["pc-memory-20261004.zip".to_string()]);
}

#[test]
fn 世代は_新しい順に_100_件だけ残し_古いものから消す() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    std::fs::create_dir_all(&backup).unwrap();
    // 2026-01-01 から 105 日分
    for i in 0..105 {
        let ms = jst_to_ms(2026, 1, 1, 23, 59, 0) + i * 86_400_000;
        std::fs::write(backup.join(backup_file_name(ms)), b"x").unwrap();
    }
    // 対象外のファイルは触らない
    std::fs::write(backup.join("pre-ver-000001-20260101000000.zip"), b"x").unwrap();
    std::fs::write(backup.join("memo.txt"), b"x").unwrap();

    let removed = prune(&backup, 100).unwrap();
    assert_eq!(removed, 5);
    let n = names(&backup);
    assert_eq!(n.iter().filter(|s| s.starts_with("pc-memory-")).count(), 100);
    assert!(!n.contains(&"pc-memory-20260101.zip".to_string()), "最も古い世代が残っている");
    assert!(n.contains(&"pre-ver-000001-20260101000000.zip".to_string()));
    assert!(n.contains(&"memo.txt".to_string()));
}

#[test]
fn 世代が上限以下なら_何も消さない() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    std::fs::create_dir_all(&backup).unwrap();
    std::fs::write(backup.join("pc-memory-20260101.zip"), b"x").unwrap();
    assert_eq!(prune(&backup, 100).unwrap(), 0);
}

#[test]
fn バックアップを作ったあとに_古い世代を消す() {
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    let c = open_and_migrate(&dir.path().join("pc-memory.db"), &backup, 1_000).unwrap();
    std::fs::create_dir_all(&backup).unwrap();
    for i in 0..3 {
        std::fs::write(backup.join(backup_file_name(jst_to_ms(2026, 1, 1 + i, 23, 59, 0))), b"x").unwrap();
    }
    run_backup(&c, &backup, jst_to_ms(2026, 10, 4, 23, 59, 0), 2).unwrap();
    // 保持 2 世代: 新しい 2 つ（今回と 1/3）だけが残る
    assert_eq!(names(&backup), vec!["pc-memory-20260103.zip".to_string(), "pc-memory-20261004.zip".to_string()]);
}
