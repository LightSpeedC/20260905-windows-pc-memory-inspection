//! 周期の実行。1 分ごとにシステムのメモリ、時間が変わったらプロセスのスナップショット、
//! 毎日のバックアップ時刻にバックアップを書く。スリープで抜けた分は、さかのぼって埋めない。

use crate::backup::{backup_file_name, is_daily_backup, run_backup};
use crate::collect::Source;
use crate::config::Config;
use crate::db::{insert_snapshot, insert_system_memory, record_event};
use crate::timeutil::{latest_slot, next_boundary};
use rusqlite::Connection;
use std::path::PathBuf;

/// バックアップに失敗したあと、同じ分の周期ごとに作り直し続けないための間隔
const BACKUP_RETRY_MS: i64 = 10 * 60_000;
/// メモリの書き込みが続けて失敗したら、DB が壊れているとみなして落とす（再起動に任せる）
const FATAL_AFTER_FAILURES: u32 = 5;

#[derive(Debug, Default)]
pub struct TickReport {
    pub snapshot: bool,
    pub backup: Option<Result<PathBuf, String>>,
    pub errors: Vec<String>,
    /// 続けて失敗している。呼び出し側は非 0 の終了コードで終わる
    pub fatal: bool,
}

pub struct Collector<S: Source> {
    conn: Connection,
    cfg: Config,
    source: S,
    /// プロセスのスナップショットを書いた区切り（周期の倍数。エポック基準）
    last_bucket: Option<i64>,
    /// システムのメモリを書いた区切り
    last_memory_bucket: Option<i64>,
    /// 最初の周期で見たバックアップのスロット。これより新しいスロットになるまで、空の DB の最初の控えは作らない
    baseline_slot: Option<i64>,
    last_backup_attempt: Option<i64>,
    memory_failures: u32,
}

impl<S: Source> Collector<S> {
    pub fn new(conn: Connection, cfg: Config, source: S) -> Self {
        Collector { conn, cfg, source, last_bucket: None, last_memory_bucket: None, baseline_slot: None, last_backup_attempt: None, memory_failures: 0 }
    }

    /// 起動した時刻から数えず、時計の区切り（毎分 hh:mm:00・毎時 hh:00:00 等）で動くための準備。
    /// 起動の時点で進行中の区切りは「済」として、次の区切りから書く（起動が 00:12:34 でも、10 秒間隔なら最初は 00:12:40）
    pub fn align_to_boundaries(&mut self, now_ms: i64) {
        self.last_memory_bucket = Some(now_ms.div_euclid(self.cfg.memory_interval_ms));
        self.last_bucket = Some(now_ms.div_euclid(self.cfg.process_interval_ms));
    }

    /// 次に動く時刻。メモリとプロセスの、近いほうの区切り（周期の倍数。エポック基準で、JST は整数時間のずれなので時計の区切りと一致する）
    pub fn next_wake(&self, now_ms: i64) -> i64 {
        next_boundary(now_ms, self.cfg.memory_interval_ms).min(next_boundary(now_ms, self.cfg.process_interval_ms))
    }

    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    pub fn record_start(&mut self, now_ms: i64) {
        let admin = if self.source.is_admin() { "あり" } else { "なし" };
        let _ = record_event(&self.conn, now_ms, "start", &format!("収集を開始しました（v{}、管理者権限{admin}）", env!("CARGO_PKG_VERSION")));
    }

    pub fn record_stop(&mut self, now_ms: i64) {
        let _ = record_event(&self.conn, now_ms, "stop", "収集を停止しました");
    }

    fn fail(&self, report: &mut TickReport, now_ms: i64, message: String) {
        let _ = record_event(&self.conn, now_ms, "error", &message);
        report.errors.push(message);
    }

    pub fn tick(&mut self, now_ms: i64) -> TickReport {
        let mut report = TickReport::default();

        // 1. システムのメモリ（毎周期）。1 分ごとの行が、そのまま生存確認になる
        // 区切り（毎分等）が変わったときだけ書く。プロセスの区切りだけで起きた周期では、メモリを重ねて書かない
        let memory_bucket = now_ms.div_euclid(self.cfg.memory_interval_ms);
        if self.last_memory_bucket != Some(memory_bucket) {
            let mem = self.source.system_memory();
            match insert_system_memory(&self.conn, now_ms, &mem) {
                Ok(()) => {
                    self.memory_failures = 0;
                    self.last_memory_bucket = Some(memory_bucket);
                }
                Err(e) => {
                    self.memory_failures += 1;
                    self.fail(&mut report, now_ms, format!("メモリの書き込みに失敗: {e}"));
                    report.fatal = self.memory_failures >= FATAL_AFTER_FAILURES;
                }
            }
        }

        // 2. プロセス（時間が変わったとき）
        let bucket = now_ms.div_euclid(self.cfg.process_interval_ms);
        if self.last_bucket != Some(bucket) {
            let (cpus, procs) = self.source.processes();
            let is_admin = self.source.is_admin();
            match insert_snapshot(&mut self.conn, now_ms, cpus, is_admin, &procs) {
                Ok(_) => {
                    self.last_bucket = Some(bucket);
                    report.snapshot = true;
                }
                Err(e) => self.fail(&mut report, now_ms, format!("プロセスの書き込みに失敗: {e}")),
            }
        }

        // 3. バックアップ
        self.backup_if_due(now_ms, &mut report);
        report
    }

    fn backup_if_due(&mut self, now_ms: i64, report: &mut TickReport) {
        let slot = latest_slot(now_ms, self.cfg.backup_hour, self.cfg.backup_minute);
        let baseline = *self.baseline_slot.get_or_insert(slot);
        let dest = self.cfg.backup_dir.join(backup_file_name(slot));
        if dest.exists() {
            return;
        }
        // 最初の起動で、空の DB の控えを作らない。ただし、すでに控えがあるなら、止まっていた間の分も作る
        let has_backups = std::fs::read_dir(&self.cfg.backup_dir)
            .map(|d| d.flatten().any(|e| is_daily_backup(&e.file_name().to_string_lossy())))
            .unwrap_or(false);
        if slot <= baseline && !has_backups {
            return;
        }
        if let Some(t) = self.last_backup_attempt {
            if now_ms - t < BACKUP_RETRY_MS {
                return;
            }
        }
        self.last_backup_attempt = Some(now_ms);
        match run_backup(&self.conn, &self.cfg.backup_dir, slot, self.cfg.keep) {
            Ok(path) => {
                let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let _ = record_event(&self.conn, now_ms, "backup", &format!("バックアップを作りました: {name}（{size} byte）"));
                report.backup = Some(Ok(path));
            }
            Err(e) => {
                self.fail(report, now_ms, format!("バックアップに失敗: {e}"));
                report.backup = Some(Err(e));
            }
        }
    }
}
