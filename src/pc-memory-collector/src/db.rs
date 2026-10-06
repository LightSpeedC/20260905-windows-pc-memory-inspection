//! DB の開き方と、書き込み。

use crate::collect::{ProcessInfo, SystemMemory};
use crate::cpu::cpu_percent;
use crate::mask::mask_paths;
use crate::migrate::{embedded_versions, migrate};
use crate::timeutil::{format_jst, parse_jst};
use rusqlite::{params, Connection, TransactionBehavior};
use std::collections::HashMap;
use std::path::Path;

/// DB を開き、足りない版を当てる。開けない・当てられないときはエラー（呼び出し側は非 0 で終わり、再起動に任せる）
pub fn open_and_migrate(db_path: &Path, backup_dir: &Path, now_ms: i64) -> Result<Connection, String> {
    if let Some(dir) = db_path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("DB の置き場を作れません: {e}"))?;
    }
    let mut conn = Connection::open(db_path).map_err(|e| format!("DB を開けません: {e}"))?;
    // WAL: 書き込みの最中でも、検知など別のプロセスが読める
    conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get::<_, String>(0)).map_err(|e| format!("DB の設定に失敗: {e}"))?;
    conn.execute_batch("PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;")
        .map_err(|e| format!("DB の設定に失敗: {e}"))?;
    migrate(&mut conn, &embedded_versions(), Some(backup_dir), now_ms)?;
    Ok(conn)
}

pub fn insert_system_memory(conn: &Connection, ts_ms: i64, m: &SystemMemory) -> rusqlite::Result<()> {
    let n = |v: u64| i64::try_from(v).unwrap_or(i64::MAX);
    conn.execute(
        "INSERT OR REPLACE INTO system_memory (measured_at, phys_total, phys_avail, swap_total, swap_used, commit_limit, commit_used)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![format_jst(ts_ms), n(m.phys_total), n(m.phys_avail), m.swap_total.map(n), m.swap_used.map(n), m.commit_limit.map(n), m.commit_used.map(n)],
    )
    .map(|_| ())
}

pub fn latest_system_memory_ts(conn: &Connection) -> rusqlite::Result<Option<i64>> {
    let latest: Option<String> = conn.query_row("SELECT MAX(measured_at) FROM system_memory", [], |r| r.get(0))?;
    Ok(latest.and_then(|text| parse_jst(&text)))
}

pub fn record_event(conn: &Connection, ts_ms: i64, kind: &str, message: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO collector_event (occurred_at, event_kind, event_message) VALUES (?1, ?2, ?3)",
        params![format_jst(ts_ms), kind, message],
    )
    .map(|_| ())
}

/// 1 回のスナップショットを書く。CPU 使用率は、前回のスナップショットの同じプロセス（pid ＋ 起動時刻）との差から出す
pub fn insert_snapshot(conn: &mut Connection, ts_ms: i64, logical_cpus: u32, is_admin: bool, procs: &[ProcessInfo]) -> rusqlite::Result<i64> {
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

    // 前回の (番号, 取得時刻 ms)。DB の日時（JST の文字列）は、経過時間の計算のため ms に戻す
    let prev: Option<(i64, i64)> = tx
        .query_row(
            "SELECT process_snapshot_id, measured_at FROM process_snapshot ORDER BY measured_at DESC, process_snapshot_id DESC LIMIT 1",
            [],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
        )
        .ok()
        .and_then(|(id, at)| parse_jst(&at).map(|ms| (id, ms)));
    let mut prev_cpu: HashMap<(u32, String), u64> = HashMap::new();
    if let Some((prev_id, _)) = prev {
        let mut stmt = tx.prepare("SELECT pid, started_at, cpu_total_ms FROM process_sample WHERE process_snapshot_id = ?1")?;
        let rows = stmt.query_map([prev_id], |r| Ok(((r.get::<_, u32>(0)?, r.get::<_, String>(1)?), r.get::<_, Option<i64>>(2)?)))?;
        for row in rows {
            let (k, v) = row?;
            // 前回読めなかった（NULL）ものは入れない。差が出せず、使用率は NULL になる
            if let Some(v) = v {
                prev_cpu.insert(k, v as u64);
            }
        }
    }

    let unreadable = procs.iter().filter(|p| p.command_line.is_none()).count() as i64;
    tx.execute(
        "INSERT INTO process_snapshot (measured_at, logical_cpu_count, process_count, command_line_unreadable_count, is_admin)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![format_jst(ts_ms), logical_cpus, procs.len() as i64, unreadable, is_admin as i64],
    )?;
    let snapshot_id = tx.last_insert_rowid();

    let mut cmd_ids: HashMap<String, i64> = HashMap::new();
    {
        let mut insert_cmd = tx.prepare("INSERT OR IGNORE INTO command_line (command_line_body) VALUES (?1)")?;
        let mut select_cmd = tx.prepare("SELECT command_line_id FROM command_line WHERE command_line_body = ?1")?;
        let mut insert_sample = tx.prepare(
            "INSERT OR REPLACE INTO process_sample
             (process_snapshot_id, pid, started_at, parent_pid, process_name, exe_path, command_line_id, cpu_total_ms, cpu_percent, memory_bytes, virtual_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        )?;
        for p in procs {
            let cmd_id = match &p.command_line {
                None => None,
                Some(text) => {
                    let masked = mask_paths(text);
                    if let Some(id) = cmd_ids.get(&masked) {
                        Some(*id)
                    } else {
                        insert_cmd.execute([&masked])?;
                        let id: i64 = select_cmd.query_row([&masked], |r| r.get(0))?;
                        cmd_ids.insert(masked, id);
                        Some(id)
                    }
                }
            };
            let started_at = format_jst(p.start_time_ms);
            let percent = match (prev, prev_cpu.get(&(p.pid, started_at.clone())), p.cpu_total_ms) {
                (Some((_, prev_ts)), Some(prev_ms), Some(now_ms)) => cpu_percent(*prev_ms, now_ms, ts_ms - prev_ts, logical_cpus),
                _ => None,
            };
            let n = |v: u64| i64::try_from(v).unwrap_or(i64::MAX);
            insert_sample.execute(params![
                snapshot_id,
                p.pid,
                started_at,
                p.parent_pid,
                p.name,
                p.exe_path.as_deref().map(mask_paths),
                cmd_id,
                p.cpu_total_ms.map(n),
                percent,
                p.memory_bytes.map(n),
                p.virtual_bytes.map(n),
            ])?;
        }
    }
    tx.commit()?;
    Ok(snapshot_id)
}
