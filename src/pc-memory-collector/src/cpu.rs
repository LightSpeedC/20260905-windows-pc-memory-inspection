//! CPU 使用率。1 回の値からは出ないため、前回の累計との差から出す。

/// 前回との差を、経過時間と論理 CPU 数で割った「全体に対する割合（%）」。タスクマネージャーと同じ数え方。
/// 累計が減った（pid の再利用など、別のプロセスの可能性）・経過時間が 0 以下・CPU 数が 0 のときは None
pub fn cpu_percent(prev_cpu_ms: u64, cur_cpu_ms: u64, elapsed_ms: i64, logical_cpus: u32) -> Option<f64> {
    if cur_cpu_ms < prev_cpu_ms || elapsed_ms <= 0 || logical_cpus == 0 {
        return None;
    }
    Some((cur_cpu_ms - prev_cpu_ms) as f64 / elapsed_ms as f64 / logical_cpus as f64 * 100.0)
}
