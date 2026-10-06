use rust_ai_pc_memory_collector::config::{parse_args, Config};
use std::path::PathBuf;

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

#[test]
fn 既定値は_仕様どおり_1_分_1_時間_23_59_100_世代() {
    let c = parse_args(&args(&["--base-dir", "X"])).unwrap();
    assert_eq!(c.memory_interval_ms, 60_000);
    assert_eq!(c.process_interval_ms, 3_600_000);
    assert_eq!((c.backup_hour, c.backup_minute), (23, 59));
    assert_eq!(c.keep, 100);
    assert_eq!(c.times, None, "既定は止まるまで回り続ける");
}

#[test]
fn db_とバックアップの置き場は_ベースの下の_data_と_backup() {
    let c = Config::new(PathBuf::from("B"));
    assert_eq!(c.data_dir, PathBuf::from("B").join("_data"));
    assert_eq!(c.backup_dir, PathBuf::from("B").join("_backup"));
    assert_eq!(c.db_path, PathBuf::from("B").join("_data").join("pc-memory.db"));
}

#[test]
fn 引数で間隔_時刻_世代数_ベースを変えられる() {
    let c = parse_args(&args(&[
        "--base-dir", "Z", "--memory-interval-sec", "2", "--process-interval-sec", "10", "--backup-at", "0:05", "--keep", "7", "--once",
    ]))
    .unwrap();
    assert_eq!(c.memory_interval_ms, 2_000);
    assert_eq!(c.process_interval_ms, 10_000);
    assert_eq!((c.backup_hour, c.backup_minute), (0, 5));
    assert_eq!(c.keep, 7);
    assert_eq!(c.times, Some(1));
    assert_eq!(c.db_path, PathBuf::from("Z").join("_data").join("pc-memory.db"));
}

// 試験用。CPU 使用率は同じプロセスが 2 回以上載らないと出ないため、1 回で終わる --once だけでは確かめられない
#[test]
fn times_で_周期の回数を決められ_once_は_1_回の別名() {
    assert_eq!(parse_args(&args(&["--times", "3"])).unwrap().times, Some(3));
    assert_eq!(parse_args(&args(&["--once"])).unwrap().times, Some(1));
}

#[test]
fn ヘルプに_times_の数え方と_cpu_使用率を確かめる例がある() {
    use rust_ai_pc_memory_collector::config::USAGE;
    assert!(USAGE.contains("--help, -h"));
    assert!(USAGE.contains("--times"));
    assert!(USAGE.contains("--memory-interval-sec 10 --process-interval-sec 10 --times 3"));
    assert!(USAGE.contains("時計の区切り"), "起動からの間隔ではなく時計の区切りで動くことを書く");
}

#[test]
fn times_は_1_以上の整数だけ() {
    assert!(parse_args(&args(&["--times", "0"])).is_err());
    assert!(parse_args(&args(&["--times", "abc"])).is_err());
    assert!(parse_args(&args(&["--times"])).is_err());
}

#[test]
fn 知らない引数や不正な値はエラー() {
    assert!(parse_args(&args(&["--nope"])).is_err());
    assert!(parse_args(&args(&["--keep", "abc"])).is_err());
    assert!(parse_args(&args(&["--keep", "0"])).is_err());
    assert!(parse_args(&args(&["--backup-at", "25:00"])).is_err());
    assert!(parse_args(&args(&["--memory-interval-sec", "0"])).is_err());
    assert!(parse_args(&args(&["--base-dir"])).is_err());
}
