import { parseLogTimestamp } from './log.ts';
import { latestSlot, type Judgement } from './report.ts';

const MINUTE_MS = 60_000;
const STALE_MS = 3 * MINUTE_MS;
// 23:59 のバックアップは、作り終えるまで数秒かかる。この間は待つ
const BACKUP_GRACE_MS = 10 * MINUTE_MS;
// 前回の結果がこの時間より古いなら、続けての異常とは見ない
const CONFIRM_WINDOW_MS = 30 * MINUTE_MS;

const DAILY_BACKUP = /^pc-memory-(\d{8})\.zip$/;

// 収集の生存確認。1 分ごとの行が、そのまま生存確認になる
export function judgeCollector(latestTs: number | null, nowMs: number, staleMs = STALE_MS): Judgement {
	if (latestTs === null) return { ok: false, reason: '収集の記録がありません（system_memory に行がありません）' };
	const age = nowMs - latestTs;
	if (age > staleMs) {
		return { ok: false, reason: `最新の行が ${Math.floor(age / MINUTE_MS)} 分前です（${staleMs / MINUTE_MS} 分を超えています）` };
	}
	return { ok: true, reason: `最新の行は ${Math.floor(age / MINUTE_MS)} 分前です` };
}

// 直近の 23:59 の分のバックアップがあるか
export function judgeBackup(names: string[], nowMs: number, collectorStartedMs: number | null): Judgement {
	const slot = latestSlot(nowMs, 23, 59);
	const date = new Date(slot + 9 * 60 * MINUTE_MS).toISOString().slice(0, 10).replaceAll('-', '');
	const dates = names.map((n) => DAILY_BACKUP.exec(n)?.[1]).filter((d): d is string => d !== undefined);
	if (dates.some((d) => d >= date)) return { ok: true, reason: `${date} の分のバックアップがあります` };
	// 収集を始めたのが、そのスロットより後なら、作る時刻がまだ来ていない
	if (collectorStartedMs !== null && collectorStartedMs > slot) {
		return { ok: true, reason: '収集の開始が直近のバックアップ時刻より後のため、まだ作る時刻が来ていません' };
	}
	if (nowMs - slot < BACKUP_GRACE_MS) return { ok: true, reason: `${date} の分のバックアップを作成中の時間です` };
	return { ok: false, reason: `${date} の分のバックアップがありません` };
}

// 前回の結果が「再確認待ち」か「異常」で、30 分以内なら、続けての異常（スリープ明けの一時的な遅れではない）
export function confirmedAgain(lastLine: string | undefined, nowMs: number): boolean {
	if (!lastLine) return false;
	const t = parseLogTimestamp(lastLine);
	if (t === null || nowMs - t > CONFIRM_WINDOW_MS) return false;
	return lastLine.includes('⚠️ 再確認待ち') || lastLine.includes('❌ 異常');
}
