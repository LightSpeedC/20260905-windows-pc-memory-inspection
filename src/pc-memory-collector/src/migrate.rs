//! DB の形を版で管理し、足りない分を順に当てる（ai-chat-lite の migrate.mjs に倣う）。
//!
//! - SQL は `src/scripts/20_migrate/ver_000001/` 等に置き、実行ファイルに埋め込む
//! - `versions` テーブルに「どこまで当てたか」と、当てた SQL の指紋（SHA-256）を持つ
//! - 当て済みの SQL が書き換えられていたら止める（環境ごとに形が違う状態を防ぐ。変更は新しい版として足す）
//! - 下りは持たない。版を上げる前に控え（zip）を取り、戻すならそこから戻す
//! - 1 つの版を 1 つのトランザクションで当て、失敗したら巻き戻す

use crate::backup::snapshot_zip;
use crate::timeutil::{format_jst, format_jst_compact};
use rusqlite::{Connection, TransactionBehavior};
use sha2::{Digest, Sha256};
use std::path::Path;

include!(concat!(env!("OUT_DIR"), "/migrations.rs"));

#[derive(Debug, Clone)]
pub struct Version {
    pub seq: u32,
    pub name: String,
    /// (ファイル名, SQL)。名前順に当てる
    pub files: Vec<(String, String)>,
}

#[derive(Debug)]
pub struct MigrateResult {
    pub from: u32,
    pub to: u32,
    pub applied: Vec<String>,
}

pub fn embedded_versions() -> Vec<Version> {
    EMBEDDED
        .iter()
        .map(|(seq, name, files)| Version {
            seq: *seq,
            name: name.to_string(),
            files: files.iter().map(|(n, s)| (n.to_string(), s.to_string())).collect(),
        })
        .collect()
}

fn sql_of(v: &Version) -> String {
    v.files.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>().join("\n")
}

fn fingerprint(text: &str) -> String {
    Sha256::digest(text.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

fn validate(versions: &[Version]) -> Result<(), String> {
    for (i, v) in versions.iter().enumerate() {
        if v.files.is_empty() {
            return Err(format!("{} に .sql がありません", v.name));
        }
        if v.seq as usize != i + 1 {
            return Err(format!("版の番号が連続していません: {}（{} が来るはずでした）", v.name, i + 1));
        }
    }
    Ok(())
}

fn table_exists(conn: &Connection, name: &str) -> rusqlite::Result<bool> {
    conn.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1", [name], |r| r.get::<_, i64>(0))
        .map(|n| n > 0)
}

// versions を持たない DB が空とは限らない。versions を作る前に数える（作ってから数えると、空の DB も使用済みになる）
fn has_any_table(conn: &Connection) -> rusqlite::Result<bool> {
    conn.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", [], |r| r.get::<_, i64>(0))
        .map(|n| n > 0)
}

fn record(conn: &Connection, seq: u32, now_ms: i64, script: &str, sha: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "INSERT INTO versions (version_seq, applied_at, script_name, sql_sha256) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![seq, format_jst(now_ms), script, sha],
    )
}

/// 足りない版を順に当てる。`pre_backup_dir` があり、すでに使われている DB なら、当てる前に控えを zip で取る
pub fn migrate(conn: &mut Connection, versions: &[Version], pre_backup_dir: Option<&Path>, now_ms: i64) -> Result<MigrateResult, String> {
    let db_err = |e: rusqlite::Error| format!("DB のエラー: {e}");
    validate(versions)?;

    let versions_existed = table_exists(conn, "versions").map_err(db_err)?;
    let already_used = has_any_table(conn).map_err(db_err)?;

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS versions (
            version_seq INTEGER PRIMARY KEY,
            applied_at  TEXT    NOT NULL CHECK (length(applied_at) = 23),
            script_name TEXT    NOT NULL,
            sql_sha256  TEXT    NOT NULL CHECK (length(sql_sha256) = 64)
        ) STRICT;",
    )
    .map_err(db_err)?;

    // versions を持たないのに使われている DB は、版 1 の形として記録する（当て直すと「テーブルがもうある」で失敗する）
    if !versions_existed && already_used {
        if let Some(first) = versions.first() {
            record(conn, first.seq, now_ms, &format!("{}（当てずに記録）", first.name), &fingerprint(&sql_of(first))).map_err(db_err)?;
        }
    }

    let rows: Vec<(u32, String)> = conn
        .prepare("SELECT version_seq, sql_sha256 FROM versions ORDER BY version_seq")
        .and_then(|mut s| s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect())
        .map_err(db_err)?;
    let from = rows.last().map(|r| r.0).unwrap_or(0);

    // 当て済みの環境では二度と実行されない。書き換えると環境ごとに形が違う状態になる
    for v in versions {
        if let Some((_, sha)) = rows.iter().find(|r| r.0 == v.seq) {
            if *sha != fingerprint(&sql_of(v)) {
                return Err(format!(
                    "当て済みの {} が書き換えられています。当て済みの環境では実行されないため、環境ごとに形が違う状態になります。新しい版として足してください。",
                    v.name
                ));
            }
        }
    }

    let pending: Vec<&Version> = versions.iter().filter(|v| !rows.iter().any(|r| r.0 == v.seq)).collect();
    let Some(last) = pending.last() else {
        return Ok(MigrateResult { from, to: from, applied: vec![] });
    };
    let to = last.seq;

    if let (Some(dir), true) = (pre_backup_dir, already_used) {
        let dest = dir.join(format!("pre-ver-{from:06}-{}.zip", format_jst_compact(now_ms)));
        snapshot_zip(conn, &dest, "pc-memory.db").map_err(|e| format!("版を上げる前の控えを取れませんでした: {e}"))?;
    }

    let mut applied = Vec::new();
    for v in pending {
        let sql = sql_of(v);
        let script = v.files.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>().join(", ");
        // 失敗したら tx を捨てて巻き戻す
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate).map_err(db_err)?;
        let run = tx.execute_batch(&sql).and_then(|_| record(&tx, v.seq, now_ms, &script, &fingerprint(&sql)).map(|_| ()));
        match run {
            Ok(()) => tx.commit().map_err(db_err)?,
            Err(e) => return Err(format!("{} を当てられませんでした: {e}", v.name)),
        }
        applied.push(v.name.clone());
    }
    Ok(MigrateResult { from, to, applied })
}
