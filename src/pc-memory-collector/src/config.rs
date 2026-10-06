//! 設定。間隔・バックアップ時刻・置き場は引数で変えられる（テストや確認で、間隔を縮めるため）。

use crate::timeutil::parse_hhmm;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Config {
    pub base_dir: PathBuf,
    pub data_dir: PathBuf,
    pub backup_dir: PathBuf,
    /// 依頼の受信箱の置き場（`<ベース>/_data/request`。中に inbox・proc・comp・error）
    pub request_dir: PathBuf,
    pub db_path: PathBuf,
    pub memory_interval_ms: i64,
    pub process_interval_ms: i64,
    pub backup_hour: u32,
    pub backup_minute: u32,
    pub keep: usize,
    /// 周期を何回回して終わるか（動作の確認用）。None は止められるまで回り続ける。`--once` は 1 回
    pub times: Option<u32>,
}

impl Config {
    /// 既定値。DB は `<ベース>/_data/pc-memory.db`、バックアップは `<ベース>/_backup/`（どちらも先頭 _ で Git 管理外）
    pub fn new(base_dir: PathBuf) -> Config {
        let data_dir = base_dir.join("_data");
        Config {
            backup_dir: base_dir.join("_backup"),
            db_path: data_dir.join("pc-memory.db"),
            request_dir: data_dir.join("request"),
            data_dir,
            base_dir,
            memory_interval_ms: 60_000,
            process_interval_ms: 3_600_000,
            backup_hour: 23,
            backup_minute: 59,
            keep: 100,
            times: None,
        }
    }
}

pub const USAGE: &str = "rust-ai-pc-memory-collector: メモリの時系列収集（1 分ごとのシステム全体・1 時間ごとの全プロセスを SQLite に書く）

使い方: rust-ai-pc-memory-collector [引数]
  --base-dir <パス>             ベースの置き場。DB は <ベース>/_data、バックアップは <ベース>/_backup（既定: カレント）
  --memory-interval-sec <秒>    システムのメモリの間隔（既定 60）
  --process-interval-sec <秒>   プロセスのスナップショットの間隔（既定 3600）
  --backup-at <hh:mm>           毎日のバックアップの時刻。JST（既定 23:59）
  --keep <件数>                 バックアップの世代数（既定 100）
  --times <回数>                周期を指定の回数だけ回して終わる（動作の確認用）
  --once                        --times 1 と同じ
  --help, -h                    この説明

動く時刻は、起動からの間隔ではなく、時計の区切り（毎分 hh:mm:00、毎時 hh:00:00。10 秒間隔なら :00 :10 :20 …）。
起動の途中の区切りは書かず、次の区切りから書く（起動が 00:12:34 で 10 秒間隔なら、最初は 00:12:40）。
そのため、既定の間隔で --once / --times を使うと、最初の実行まで最大 1 分待つ。すぐ試すなら --memory-interval-sec 1 を付ける。
--times が数えるのは、区切りで動いた回数（メモリの区切りと、プロセスの区切りの、どちらか近いほう）。
プロセスのスナップショットは、プロセスの間隔（--process-interval-sec）の区切りが変わったときだけ書く。
CPU 使用率は、同じプロセスが 2 回以上スナップショットに載らないと出ない。確かめるときは、プロセスの間隔を
メモリの間隔以下にして、3 回以上回す。
  例: --memory-interval-sec 10 --process-interval-sec 10 --times 3
権限が無くて読めないプロセスの、メモリ・仮想メモリ・CPU 累計・CPU 使用率は NULL で書く（0 にしない）。";

pub fn parse_args(args: &[String]) -> Result<Config, String> {
    let mut base: Option<PathBuf> = None;
    let mut memory_sec: Option<i64> = None;
    let mut process_sec: Option<i64> = None;
    let mut backup_at: Option<(u32, u32)> = None;
    let mut keep: Option<usize> = None;
    let mut times: Option<u32> = None;

    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut value = |name: &str| it.next().cloned().ok_or(format!("{name} に値がありません"));
        match a.as_str() {
            "--base-dir" => base = Some(PathBuf::from(value(a)?)),
            "--memory-interval-sec" => memory_sec = Some(positive(&value(a)?, a)?),
            "--process-interval-sec" => process_sec = Some(positive(&value(a)?, a)?),
            "--backup-at" => {
                let v = value(a)?;
                backup_at = Some(parse_hhmm(&v).ok_or(format!("--backup-at は hh:mm の形で指定してください: {v}"))?);
            }
            "--keep" => keep = Some(positive(&value(a)?, a)? as usize),
            "--times" => times = Some(u32::try_from(positive(&value(a)?, a)?).map_err(|_| format!("{a} が大きすぎます"))?),
            "--once" => times = Some(1),
            other => return Err(format!("知らない引数です: {other}")),
        }
    }

    let base = match base {
        Some(b) => b,
        None => std::env::current_dir().map_err(|e| format!("カレントを取れません: {e}"))?,
    };
    let mut c = Config::new(base);
    if let Some(s) = memory_sec {
        c.memory_interval_ms = s * 1_000;
    }
    if let Some(s) = process_sec {
        c.process_interval_ms = s * 1_000;
    }
    if let Some((h, m)) = backup_at {
        c.backup_hour = h;
        c.backup_minute = m;
    }
    if let Some(k) = keep {
        c.keep = k;
    }
    c.times = times;
    Ok(c)
}

fn positive(v: &str, name: &str) -> Result<i64, String> {
    match v.parse::<i64>() {
        Ok(n) if n > 0 => Ok(n),
        _ => Err(format!("{name} は 1 以上の整数で指定してください: {v}")),
    }
}
