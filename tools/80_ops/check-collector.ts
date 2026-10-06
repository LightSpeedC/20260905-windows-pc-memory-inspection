// 収集（rust-ai-pc-memory-collector）が止まっていないかを確かめ、結果を logs/check-collector.log に残す。
// 1 分ごとの行（system_memory）の新しさと、毎日のバックアップの有無を見る。
// 最初の異常は「再確認待ち」としてログだけに残し、続けて異常のとき（10 分おきの次の確認）だけ、
// トースト通知を出す（「ログを開く」ボタン付き）。スリープ明けの一時的な遅れで、通知しないため。
// 引数（どちらも動作の確認用）
//   now:<ISO 日時>  確認する時刻を指定する（省略時は現在）
//   base:<パス>     DB・バックアップ・ログの置き場（省略時はプロジェクトのルート）
import { existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { confirmedAgain, judgeBackup, judgeCollector } from './lib/collector.ts';
import { appendLog, parseLogTimestamp } from './lib/log.ts';
import { formatPending, formatResult } from './lib/report.ts';
import { showToast } from './lib/toast.ts';

const argv = process.argv.slice(2);
const baseArg = argv.find((a) => a.toLowerCase().startsWith('base:'));
const root = baseArg ? baseArg.slice('base:'.length) : join(import.meta.dirname, '..', '..');
const logFile = join(root, 'logs', 'check-collector.log');
mkdirSync(dirname(logFile), { recursive: true });
const dbPath = join(root, '_data', 'pc-memory.db');
const backupDir = join(root, '_backup');

const nowArg = argv.find((a) => a.toLowerCase().startsWith('now:'));
const now = nowArg ? new Date(nowArg.slice('now:'.length)) : new Date();
if (Number.isNaN(now.getTime())) {
	appendLog(logFile, `中断: now: の日時を読めません: ${nowArg}`);
	process.exit(2);
}
const nowMs = now.getTime();

let latestTs: number | null = null;
let startedMs: number | null = null;
let dbError = '';
if (!existsSync(dbPath)) {
	dbError = 'DB がありません（収集が一度も動いていません）';
} else {
	try {
		// 読み取り専用で開く。収集が書き込み中でも読める（WAL）
		const db = new DatabaseSync(dbPath, { readOnly: true });
		try {
			// DB の日時は JST の 23 文字（yyyy/mm/dd hh:mm:ss.ccc）。ログの行頭と同じ形なので同じ関数で読める
			const latestAt = (db.prepare('SELECT MAX(measured_at) AS t FROM system_memory').get() as { t: string | null }).t;
			const startedAt = (db.prepare("SELECT MIN(occurred_at) AS t FROM collector_event WHERE event_kind = 'start'").get() as { t: string | null }).t;
			latestTs = latestAt === null ? null : parseLogTimestamp(latestAt);
			startedMs = startedAt === null ? null : parseLogTimestamp(startedAt);
		} finally {
			db.close();
		}
	} catch (e) {
		dbError = `DB を読めません: ${e instanceof Error ? e.message : String(e)}`;
	}
}

const collector = dbError ? { ok: false, reason: dbError } : judgeCollector(latestTs, nowMs);
const backupNames = existsSync(backupDir) ? readdirSync(backupDir) : [];
const backup = judgeBackup(backupNames, nowMs, startedMs);

const ok = collector.ok && backup.ok;
const reason = ok
	? `${collector.reason}。${backup.reason}`
	: [collector, backup]
			.filter((j) => !j.ok)
			.map((j) => j.reason)
			.join('。');

const lastLine = existsSync(logFile)
	? readFileSync(logFile, 'utf8').split(/\r?\n/).filter(Boolean).at(-1)
	: undefined;

if (ok) {
	appendLog(logFile, formatResult({ ok, reason }));
	process.exit(0);
}
if (!confirmedAgain(lastLine, nowMs)) {
	appendLog(logFile, formatPending({ ok, reason }));
	process.exit(0);
}
appendLog(logFile, formatResult({ ok, reason }));
const rc = showToast('メモリの時系列収集が止まっています', reason, pathToFileURL(logFile).href);
if (rc !== 0) appendLog(logFile, `トーストの表示に失敗しました（終了コード ${rc}）`);
process.exit(1);
