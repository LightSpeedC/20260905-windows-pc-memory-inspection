use rust_ai_pc_memory_collector::cpu::cpu_percent;

#[test]
fn cpu_使用率は_累計の差を_経過時間と論理_cpu_数で割る() {
    // 1 時間（3,600,000 ms）で CPU を 30,000 ms 使い、論理 CPU が 8 つ → 30000 / 3600000 / 8 * 100
    let p = cpu_percent(1_000, 31_000, 3_600_000, 8).unwrap();
    assert!((p - 0.104_166_666).abs() < 1e-6, "{p}");
}

#[test]
fn 全コアを使い切れば_100_パーセント() {
    let p = cpu_percent(0, 8_000, 1_000, 8).unwrap();
    assert!((p - 100.0).abs() < 1e-9, "{p}");
}

// pid の再利用などで、別のプロセスになっている可能性があるため
#[test]
fn 前回より累計が減ったときは_null() {
    assert_eq!(cpu_percent(5_000, 4_000, 1_000, 8), None);
}

#[test]
fn 経過時間が_0_以下のときは_null() {
    assert_eq!(cpu_percent(0, 100, 0, 8), None);
    assert_eq!(cpu_percent(0, 100, -5, 8), None);
}

#[test]
fn 論理_cpu_数が_0_のときは_null() {
    assert_eq!(cpu_percent(0, 100, 1_000, 0), None);
}
