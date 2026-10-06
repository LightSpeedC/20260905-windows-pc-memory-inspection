use rust_ai_pc_memory_collector::timeutil::*;

// DB に持つ日時は JST の 23 文字（yyyy/mm/dd hh:mm:ss.ccc）。読み戻して同じ時刻になること
#[test]
fn jst_の_23_文字の日時は_書いて読み戻すと同じ時刻になる() {
    for ms in [0, 1, 999, 1_791_072_306_007, jst_to_ms(2026, 12, 31, 23, 59, 59) + 999] {
        let text = format_jst(ms);
        assert_eq!(text.len(), 23, "{text}");
        assert_eq!(parse_jst(&text), Some(ms), "{text}");
    }
}

#[test]
fn jst_の日時として読めない文字列は_none() {
    assert_eq!(parse_jst(""), None);
    assert_eq!(parse_jst("2026-10-04 09:00:00.000"), None, "区切りが - のもの");
    assert_eq!(parse_jst("2026/10/04 09:00:00"), None, "ミリ秒が無いもの");
    assert_eq!(parse_jst("2026/10/04 09:00:00.000x"), None, "24 文字");
}

#[test]
fn jst_の日時の文字列は_辞書順がそのまま時系列順() {
    let a = format_jst(jst_to_ms(2026, 10, 4, 9, 0, 0));
    let b = format_jst(jst_to_ms(2026, 10, 4, 9, 0, 0) + 1);
    let c = format_jst(jst_to_ms(2026, 10, 5, 0, 0, 0));
    assert!(a < b && b < c);
}

// 基準: 2026-10-04T00:05:06.007Z = JST 2026/10/04 09:05:06.007
const ANCHOR_MS: i64 = 1_791_072_306_007;

#[test]
fn 日時は_jst_の_yyyy_mm_dd_hh_mm_ss_ccc_で書く() {
    assert_eq!(format_jst(ANCHOR_MS), "2026/10/04 09:05:06.007");
}

#[test]
fn 日付をまたぐときも_jst_で数える() {
    // UTC 15:00 は JST の翌日 0:00
    assert_eq!(format_jst(jst_to_ms(2026, 10, 5, 0, 0, 0)), "2026/10/05 00:00:00.000");
}

#[test]
fn jst_から_エポックへの変換は_基準と一致する() {
    assert_eq!(jst_to_ms(2026, 10, 4, 9, 5, 6) + 7, ANCHOR_MS);
    assert_eq!(jst_to_ms(1970, 1, 1, 9, 0, 0), 0);
}

#[test]
fn うるう年の_2_月_29_日も数えられる() {
    assert_eq!(format_jst(jst_to_ms(2028, 2, 29, 23, 59, 59)), "2028/02/29 23:59:59.000");
}

#[test]
fn 次の区切りは_現在より後で_最も近い周期の倍数() {
    assert_eq!(next_boundary(60_000, 60_000), 120_000);
    assert_eq!(next_boundary(60_001, 60_000), 120_000);
    assert_eq!(next_boundary(119_999, 60_000), 120_000);
    assert_eq!(next_boundary(0, 60_000), 60_000);
}

#[test]
fn 直近のスロットは_指定の時刻より前で最も新しい_jst_の_hh_mm() {
    let day = |d, h, m, s| jst_to_ms(2026, 10, d, h, m, s);
    // 23:59 ちょうどは、その日のスロット
    assert_eq!(latest_slot(day(4, 23, 59, 0), 23, 59), day(4, 23, 59, 0));
    // 23:58 は、前日のスロット
    assert_eq!(latest_slot(day(4, 23, 58, 59), 23, 59), day(3, 23, 59, 0));
    // 翌日 0:05 は、前日 23:59
    assert_eq!(latest_slot(day(5, 0, 5, 0), 23, 59), day(4, 23, 59, 0));
}

#[test]
fn スロットの日付は_jst_の_yyyymmdd() {
    assert_eq!(slot_date(jst_to_ms(2026, 10, 4, 23, 59, 0)), "20261004");
}

#[test]
fn hh_mm_の解釈() {
    assert_eq!(parse_hhmm("23:59"), Some((23, 59)));
    assert_eq!(parse_hhmm("0:05"), Some((0, 5)));
    assert_eq!(parse_hhmm("24:00"), None);
    assert_eq!(parse_hhmm("12:60"), None);
    assert_eq!(parse_hhmm("abc"), None);
}
