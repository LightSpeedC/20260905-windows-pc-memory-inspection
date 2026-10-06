import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
	formatPending,
	formatResult,
	isFinalCheck,
	judgeReports,
	parseReportTime,
	scheduledSlot,
} from '../tools/80_ops/lib/report.ts';

// 時刻はすべて JST で書き、new Date(…+09:00) で作る
const jst = (s: string) => new Date(s + '+09:00');
const rep = (name: string) => `logs\\2026\\202610\\${name.slice(0, 8)}\\${name}-mem-admin-log.html`;

test('予定時刻は 0・6・12・18 時のうち、いまより前で最も新しいもの', () => {
	assert.deepEqual(scheduledSlot(jst('2026-10-04T00:15:00')), jst('2026-10-04T00:00:00'));
	assert.deepEqual(scheduledSlot(jst('2026-10-04T05:59:59')), jst('2026-10-04T00:00:00'));
	assert.deepEqual(scheduledSlot(jst('2026-10-04T06:00:00')), jst('2026-10-04T06:00:00'));
	assert.deepEqual(scheduledSlot(jst('2026-10-04T23:59:59')), jst('2026-10-04T18:00:00'));
});

test('予定時刻は実行環境のタイムゾーンに関係なく JST で数える', () => {
	// UTC の 2026-10-03T15:15 は JST の 10-04 00:15
	assert.deepEqual(scheduledSlot(new Date('2026-10-03T15:15:00Z')), jst('2026-10-04T00:00:00'));
});

test('レポートの時刻は、ファイル名の yyyymmdd-hhmmss（JST）から読む', () => {
	assert.deepEqual(parseReportTime(rep('20261004-082911')), jst('2026-10-04T08:29:11'));
});

test('ファイル名が形に合わないときは null', () => {
	assert.equal(parseReportTime('logs\\x\\abc.html'), null);
});

test('予定時刻以降に、ch06 付きのレポートがあれば正常', () => {
	const r = judgeReports([rep('20261004-000002')], jst('2026-10-04T00:15:00'), () => true);
	assert.equal(r.ok, true);
});

test('予定時刻以降のレポートが無ければ異常（前の予定のレポートは数えない）', () => {
	const r = judgeReports([rep('20261003-180002')], jst('2026-10-04T00:15:00'), () => true);
	assert.equal(r.ok, false);
	assert.match(r.reason, /レポートがありません/);
});

test('レポートはあるが ch06 が無ければ異常', () => {
	const r = judgeReports([rep('20261004-000002')], jst('2026-10-04T00:15:00'), () => false);
	assert.equal(r.ok, false);
	assert.match(r.reason, /ch06/);
});

test('手動で作ったレポートも、予定時刻以降で ch06 があれば正常に数える', () => {
	const paths = [rep('20261004-000002'), rep('20261004-001000')];
	const r = judgeReports(paths, jst('2026-10-04T00:15:00'), (p) => p.includes('001000'));
	assert.equal(r.ok, true);
});

test('ログの 1 行は、正常なら ✅、異常なら ❌ を結果の語の前に付ける（共通ルールの絵文字）', () => {
	assert.equal(formatResult({ ok: true, reason: '理由A' }), '✅ 正常 理由A');
	assert.equal(formatResult({ ok: false, reason: '理由B' }), '❌ 異常 理由B');
});

test('確認は :15 と :45 の 2 回。:30 以降なら最終の確認（スリープ明けの遅れを :45 まで待つ）', () => {
	assert.equal(isFinalCheck(jst('2026-10-04T00:15:00')), false);
	assert.equal(isFinalCheck(jst('2026-10-04T12:29:59')), false);
	assert.equal(isFinalCheck(jst('2026-10-04T12:30:00')), true);
	assert.equal(isFinalCheck(jst('2026-10-04T18:45:00')), true);
});

test('最終ではない確認で異常のときは、通知せず「⚠️ 再確認待ち」と書く', () => {
	assert.equal(formatPending({ ok: false, reason: '理由C' }), '⚠️ 再確認待ち 理由C');
});

test('記録が空なら異常', () => {
	const r = judgeReports([], jst('2026-10-04T00:15:00'), () => true);
	assert.equal(r.ok, false);
});
