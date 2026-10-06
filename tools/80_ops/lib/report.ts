import { formatTimestamp } from './log.ts';

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;
const SLOT_HOURS = 6;

// 定時（0・6・12・18 時）のうち、now より前で最も新しいもの
export function scheduledSlot(now: Date): Date {
	const j = new Date(now.getTime() + JST_OFFSET_MS);
	const slotHour = Math.floor(j.getUTCHours() / SLOT_HOURS) * SLOT_HOURS;
	return new Date(Date.UTC(j.getUTCFullYear(), j.getUTCMonth(), j.getUTCDate(), slotHour) - JST_OFFSET_MS);
}

// now（エポック・ミリ秒）以前で最も新しい、JST の hour:minute:00 の時刻（エポック・ミリ秒）
export function latestSlot(nowMs: number, hour: number, minute: number): number {
	const DAY_MS = 24 * 60 * 60 * 1000;
	const local = nowMs + JST_OFFSET_MS;
	let slot = Math.floor(local / DAY_MS) * DAY_MS + hour * 3_600_000 + minute * 60_000;
	if (slot > local) slot -= DAY_MS;
	return slot - JST_OFFSET_MS;
}

// ファイル名の yyyymmdd-hhmmss（JST）から、レポートを作った時刻を読む
export function parseReportTime(path: string): Date | null {
	const name = path.split(/[\\/]/).pop() ?? '';
	const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-mem-admin-log\.html$/.exec(name);
	if (!m) return null;
	const [y, mo, d, h, mi, s] = m.slice(1).map(Number) as [number, number, number, number, number, number];
	return new Date(Date.UTC(y, mo - 1, d, h, mi, s) - JST_OFFSET_MS);
}

export interface Judgement {
	ok: boolean;
	reason: string;
}

// 確認は :15 と :45 の 2 回。:30 以降は最終の確認で、異常ならここで通知する。
// :15 の異常は、スリープ明けの遅れかもしれないため、通知せず :45 の再確認に回す
export function isFinalCheck(now: Date): boolean {
	return new Date(now.getTime() + JST_OFFSET_MS).getUTCMinutes() >= 30;
}

// 最終ではない確認での異常。⚠️（警告）として書き、通知しない
export function formatPending(j: Judgement): string {
	return `⚠️ 再確認待ち ${j.reason}`;
}

// ログの 1 行。結果の語の前に、共通ルールの絵文字（✅ 成功・❌ 失敗）を付ける
export function formatResult(j: Judgement): string {
	return `${j.ok ? '✅ 正常' : '❌ 異常'} ${j.reason}`;
}

// 直近の定時以降に、ch06 付きのレポートがあれば正常。手動で作ったものも数える
export function judgeReports(paths: string[], now: Date, hasCh06: (path: string) => boolean): Judgement {
	const slot = scheduledSlot(now);
	const label = formatTimestamp(slot).slice(0, 16);
	const recent = paths.filter((p) => {
		const t = parseReportTime(p);
		return t !== null && t.getTime() >= slot.getTime();
	});
	if (recent.length === 0) {
		return { ok: false, reason: `${label} 以降のレポートがありません` };
	}
	if (!recent.some((p) => hasCh06(p))) {
		return { ok: false, reason: `${label} 以降のレポートに ch06 がありません` };
	}
	return { ok: true, reason: `${label} 以降のレポートがあり、ch06 も書かれています` };
}
