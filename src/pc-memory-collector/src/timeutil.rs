//! 時刻の扱い。時刻は UTC のエポック（ミリ秒）で持ち、表示・日付・定時は JST で数える。
//! 実行環境のタイムゾーンに関係なく JST にする（共通ルールの「日時は JST」に従う）。

use std::time::{SystemTime, UNIX_EPOCH};

pub const JST_OFFSET_MS: i64 = 9 * 3_600_000;
const HOUR_MS: i64 = 3_600_000;
const MINUTE_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;

pub fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

// 1970-01-01 からの日数 → (年, 月, 日)。Howard Hinnant の civil_from_days
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

// (年, 月, 日) → 1970-01-01 からの日数
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if month > 2 { month - 3 } else { month + 9 } as u64;
    let doy = (153 * mp + 2) / 5 + day as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe as i64 - 719_468
}

/// JST の日時 → エポック（ミリ秒）
pub fn jst_to_ms(year: i64, month: u32, day: u32, hour: u32, minute: u32, second: u32) -> i64 {
    days_from_civil(year, month, day) * DAY_MS
        + hour as i64 * HOUR_MS
        + minute as i64 * MINUTE_MS
        + second as i64 * 1_000
        - JST_OFFSET_MS
}

/// `yyyy/mm/dd hh:mm:ss.ccc`（JST。ミリ秒 3 桁）
pub fn format_jst(ms: i64) -> String {
    let local = ms + JST_OFFSET_MS;
    let (y, mo, d) = civil_from_days(local.div_euclid(DAY_MS));
    let rem = local.rem_euclid(DAY_MS);
    format!(
        "{y:04}/{mo:02}/{d:02} {:02}:{:02}:{:02}.{:03}",
        rem / HOUR_MS,
        rem % HOUR_MS / MINUTE_MS,
        rem % MINUTE_MS / 1_000,
        rem % 1_000
    )
}

/// `format_jst` の逆。`yyyy/mm/dd hh:mm:ss.ccc`（固定 23 文字）だけを読み、それ以外は None
pub fn parse_jst(text: &str) -> Option<i64> {
    let b = text.as_bytes();
    if b.len() != 23 || b[4] != b'/' || b[7] != b'/' || b[10] != b' ' || b[13] != b':' || b[16] != b':' || b[19] != b'.' {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> {
        let s = text.get(from..to)?;
        s.bytes().all(|c| c.is_ascii_digit()).then(|| s.parse().ok()).flatten()
    };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s, ms) = (num(11, 13)?, num(14, 16)?, num(17, 19)?, num(20, 23)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || s > 59 {
        return None;
    }
    Some(jst_to_ms(y, mo as u32, d as u32, h as u32, mi as u32, s as u32) + ms)
}

/// `yyyymmddhhmmss`（JST）。ファイル名に使う
pub fn format_jst_compact(ms: i64) -> String {
    format_jst(ms).chars().filter(|c| c.is_ascii_digit()).take(14).collect()
}

/// now より後で、最も近い周期の倍数（エポック基準）
pub fn next_boundary(ms: i64, period_ms: i64) -> i64 {
    (ms.div_euclid(period_ms) + 1) * period_ms
}

/// now 以前で最も新しい、JST の hh:mm:00 の時刻
pub fn latest_slot(now_ms: i64, hour: u32, minute: u32) -> i64 {
    let local = now_ms + JST_OFFSET_MS;
    let mut slot = local.div_euclid(DAY_MS) * DAY_MS + hour as i64 * HOUR_MS + minute as i64 * MINUTE_MS;
    if slot > local {
        slot -= DAY_MS;
    }
    slot - JST_OFFSET_MS
}

/// スロットの JST の日付 `yyyymmdd`
pub fn slot_date(slot_ms: i64) -> String {
    let (y, mo, d) = civil_from_days((slot_ms + JST_OFFSET_MS).div_euclid(DAY_MS));
    format!("{y:04}{mo:02}{d:02}")
}

pub fn parse_hhmm(s: &str) -> Option<(u32, u32)> {
    let (h, m) = s.split_once(':')?;
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    (h < 24 && m < 60).then_some((h, m))
}
