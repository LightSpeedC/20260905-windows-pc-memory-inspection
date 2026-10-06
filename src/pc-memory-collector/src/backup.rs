//! DB のバックアップ。`VACUUM INTO` で整合の取れたコピーを作り、検査して、zip にする。
//! 稼働中の DB 本体をコピーすると -wal 側の分が落ちるが、`VACUUM INTO` なら 1 つに揃う。

use crate::timeutil::slot_date;
use rusqlite::{Connection, OpenFlags};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const PREFIX: &str = "pc-memory-";
const SUFFIX: &str = ".zip";

pub fn backup_file_name(slot_ms: i64) -> String {
    format!("{PREFIX}{}{SUFFIX}", slot_date(slot_ms))
}

// 毎日のバックアップの名前の形（pc-memory-yyyymmdd.zip）。pre-ver-… などは含めない
pub fn is_daily_backup(name: &str) -> bool {
    name.len() == PREFIX.len() + 8 + SUFFIX.len()
        && name.starts_with(PREFIX)
        && name.ends_with(SUFFIX)
        && name[PREFIX.len()..PREFIX.len() + 8].bytes().all(|b| b.is_ascii_digit())
}

// DB 本体のほか、-wal と -shm も 3 つ揃えて消す
fn remove_db_files(path: &Path) {
    let _ = fs::remove_file(path);
    for ext in ["-wal", "-shm", "-journal"] {
        let mut p = path.as_os_str().to_owned();
        p.push(ext);
        let _ = fs::remove_file(PathBuf::from(p));
    }
}

fn integrity_check(path: &Path) -> Result<(), String> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("控えを開けません: {e}"))?;
    let r: String = c.query_row("PRAGMA integrity_check", [], |r| r.get(0)).map_err(|e| format!("整合性の検査に失敗: {e}"))?;
    if r == "ok" {
        Ok(())
    } else {
        Err(format!("整合性の検査が通りません: {r}"))
    }
}

fn write_zip(src: &Path, dest_tmp: &Path, entry_name: &str) -> Result<(), String> {
    let file = fs::File::create(dest_tmp).map_err(|e| format!("zip を作れません: {e}"))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    zip.start_file(entry_name, options).map_err(|e| format!("zip への書き込みに失敗: {e}"))?;
    let mut input = fs::File::open(src).map_err(|e| format!("控えを読めません: {e}"))?;
    io::copy(&mut input, &mut zip).map_err(|e| format!("zip への書き込みに失敗: {e}"))?;
    let file = zip.finish().map_err(|e| format!("zip を閉じられません: {e}"))?;
    file.sync_all().map_err(|e| format!("zip を保存できません: {e}"))?;
    Ok(())
}

/// 稼働中の DB から、整合した控えを 1 つ作り、検査して、zip（1 エントリ）にする。
/// 一時名で書いてから名前を変える。途中で止まっても、壊れた zip を残さない
pub fn snapshot_zip(conn: &Connection, dest_zip: &Path, entry_name: &str) -> Result<(), String> {
    let dir = dest_zip.parent().ok_or("保存先の置き場が分かりません")?;
    fs::create_dir_all(dir).map_err(|e| format!("置き場を作れません: {e}"))?;
    let tmp_db = dir.join(format!(".tmp-snapshot-{}.db", std::process::id()));
    let mut tmp_zip = dest_zip.as_os_str().to_owned();
    tmp_zip.push(".tmp");
    let tmp_zip = PathBuf::from(tmp_zip);

    remove_db_files(&tmp_db);
    let result = (|| {
        conn.execute("VACUUM INTO ?1", [tmp_db.to_string_lossy().as_ref()]).map_err(|e| format!("控えを作れません: {e}"))?;
        integrity_check(&tmp_db)?;
        write_zip(&tmp_db, &tmp_zip, entry_name)?;
        fs::rename(&tmp_zip, dest_zip).map_err(|e| format!("zip の名前を変えられません: {e}"))
    })();
    remove_db_files(&tmp_db);
    if result.is_err() {
        let _ = fs::remove_file(&tmp_zip);
    }
    result
}

/// 毎日のバックアップ。新しい世代を書き終えてから、古い世代を消す
pub fn run_backup(conn: &Connection, backup_dir: &Path, slot_ms: i64, keep: usize) -> Result<PathBuf, String> {
    let dest = backup_dir.join(backup_file_name(slot_ms));
    snapshot_zip(conn, &dest, "pc-memory.db")?;
    prune(backup_dir, keep)?;
    Ok(dest)
}

/// 毎日のバックアップを、名前の新しい順に keep 件だけ残す。消した件数を返す。それ以外のファイルは触らない
pub fn prune(dir: &Path, keep: usize) -> Result<usize, String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .map_err(|e| format!("置き場を読めません: {e}"))?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| is_daily_backup(n))
        .collect();
    names.sort();
    let excess = names.len().saturating_sub(keep);
    for n in &names[..excess] {
        fs::remove_file(dir.join(n)).map_err(|e| format!("古い世代を消せません: {e}"))?;
    }
    Ok(excess)
}
