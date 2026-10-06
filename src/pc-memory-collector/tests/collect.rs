use rust_ai_pc_memory_collector::collect::is_unreadable;

// 実測（非管理者）: 読めないプロセス 261 件は、メモリが 0 かつ実行ファイルのパスも無い、が完全に一致した。
// OS の中核（System・csrss・smss・winlogon 等）が該当する
#[test]
fn メモリが_0_で_パスも無いものは_読めなかったとみなす() {
    assert!(is_unreadable(0, false));
}

#[test]
fn メモリが_0_でも_パスが取れていれば_本当に_0_とみなす() {
    assert!(!is_unreadable(0, true));
}

#[test]
fn メモリが取れていれば_読めたとみなす() {
    assert!(!is_unreadable(1, false));
    assert!(!is_unreadable(4096, true));
}
