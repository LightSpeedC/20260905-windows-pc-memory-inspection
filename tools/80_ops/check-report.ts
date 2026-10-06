// 定時のレポートが作られたかを確かめ、結果を logs/check-report.log に残す。
// 確認は :15 と :45 の 2 回。:15 の異常は「再確認待ち」としてログだけに残し、
// :45 でもなお異常のときだけ、トースト通知を出す（「ログを開く」ボタン付き）。
// 引数: now:<ISO 日時>  確認する時刻を指定する（動作の確認用。省略時は現在）
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { appendLog } from './lib/log.ts';
import { formatPending, formatResult, isFinalCheck, judgeReports } from './lib/report.ts';
import { showToast } from './lib/toast.ts';

const root = join(import.meta.dirname, '..', '..');
const logFile = join(root, 'logs', 'check-report.log');

const nowArg = process.argv.slice(2).find((a) => a.toLowerCase().startsWith('now:'));
const now = nowArg ? new Date(nowArg.slice('now:'.length)) : new Date();
if (Number.isNaN(now.getTime())) {
	appendLog(logFile, `中断: now: の日時を読めません: ${nowArg}`);
	process.exit(2);
}

const listFile = join(root, 'logs', 'reports-admin.txt');
const paths = existsSync(listFile)
	? readFileSync(listFile, 'utf8')
			.replace(/^﻿/, '')
			.split(/\r?\n/)
			.map((l) => l.trim())
			.filter(Boolean)
	: [];

// レポートは約 600 KB あるため、判定に必要になったものだけ読む
const hasCh06 = (p: string): boolean => {
	const file = join(root, p);
	return existsSync(file) && readFileSync(file, 'utf8').includes('id="ch06"');
};

const result = judgeReports(paths, now, hasCh06);
const final = isFinalCheck(now);
// :15 の異常は、スリープ明けの遅れかもしれない。通知せず、:45 の再確認に回す
appendLog(logFile, !result.ok && !final ? formatPending(result) : formatResult(result));

if (!result.ok && !final) process.exit(0);

if (!result.ok) {
	const rc = showToast('メモリ調査レポートが作られていません', result.reason, pathToFileURL(logFile).href);
	if (rc !== 0) appendLog(logFile, `トーストの表示に失敗しました（終了コード ${rc}）`);
}
process.exit(result.ok ? 0 : 1);
