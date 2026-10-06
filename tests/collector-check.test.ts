import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { confirmedAgain, judgeBackup, judgeCollector } from '../tools/80_ops/lib/collector.ts';
import { parseLogTimestamp } from '../tools/80_ops/lib/log.ts';

// 時刻はすべて JST で書き、エポック（ミリ秒）にする
const jst = (s: string): number => new Date(s + '+09:00').getTime();
const MIN = 60_000;

test('最新の行が 3 分以内なら、収集は正常', () => {
	const now = jst('2026-10-04T22:00:00');
	assert.equal(judgeCollector(now - 2 * MIN, now).ok, true);
	assert.equal(judgeCollector(now - 3 * MIN, now).ok, true);
});

test('最新の行が 3 分より古ければ異常（理由に経過の分数を書く）', () => {
	const now = jst('2026-10-04T22:00:00');
	const r = judgeCollector(now - 10 * MIN, now);
	assert.equal(r.ok, false);
	assert.match(r.reason, /10 分前/);
});

test('行が 1 件も無ければ異常', () => {
	const r = judgeCollector(null, jst('2026-10-04T22:00:00'));
	assert.equal(r.ok, false);
	assert.match(r.reason, /記録がありません/);
});

test('直近の 23:59 の分のバックアップがあれば正常', () => {
	const r = judgeBackup(['pc-memory-20261004.zip'], jst('2026-10-05T00:30:00'), jst('2026-09-01T00:00:00'));
	assert.equal(r.ok, true);
});

test('直近の 23:59 の分のバックアップが無ければ異常（作成中の 10 分は待つ）', () => {
	const names = ['pc-memory-20261003.zip'];
	const started = jst('2026-09-01T00:00:00');
	assert.equal(judgeBackup(names, jst('2026-10-05T00:05:00'), started).ok, true, '23:59 から 10 分以内');
	const r = judgeBackup(names, jst('2026-10-05T00:30:00'), started);
	assert.equal(r.ok, false);
	assert.match(r.reason, /20261004/);
});

test('収集を始めたのが、直近の 23:59 より後なら、まだ作る時刻が来ていないので正常', () => {
	const r = judgeBackup([], jst('2026-10-05T12:00:00'), jst('2026-10-05T09:00:00'));
	assert.equal(r.ok, true);
});

test('毎日のバックアップ以外のファイル名は数えない', () => {
	const r = judgeBackup(['pre-ver-000001-20261004000000.zip', 'memo.txt'], jst('2026-10-05T12:00:00'), jst('2026-09-01T00:00:00'));
	assert.equal(r.ok, false);
});

// 実物と同じ列名・日時の形（JST の 23 文字）の DB を作って、検知を通す。
// 列名や日時の形が変わっても、検知が「DB を読めません」で黙って異常になる、のを防ぐ
test('実物と同じ形の DB を読んで、収集が動いていれば正常と判定する', () => {
	const base = mkdtempSync(join(tmpdir(), 'check-collector-'));
	try {
		mkdirSync(join(base, '_data'));
		mkdirSync(join(base, '_backup'));
		writeFileSync(join(base, '_backup', 'pc-memory-20261003.zip'), '');
		const db = new DatabaseSync(join(base, '_data', 'pc-memory.db'));
		db.exec(`
			CREATE TABLE system_memory (measured_at TEXT PRIMARY KEY CHECK (length(measured_at) = 23), phys_total INTEGER NOT NULL, phys_avail INTEGER NOT NULL) STRICT;
			CREATE TABLE collector_event (collector_event_id INTEGER PRIMARY KEY, occurred_at TEXT NOT NULL, event_kind TEXT NOT NULL, event_message TEXT NOT NULL) STRICT;
			INSERT INTO system_memory VALUES ('2026/10/04 21:59:30.000', 1, 1);
			INSERT INTO collector_event (occurred_at, event_kind, event_message) VALUES ('2026/09/01 00:00:00.000', 'start', 'x');
		`);
		db.close();
		const r = spawnSync(process.execPath, [join(import.meta.dirname, '..', 'tools', '80_ops', 'check-collector.ts'), `base:${base}`, 'now:2026-10-04T22:00:00+09:00'], {
			encoding: 'utf8',
			timeout: 30_000,
		});
		assert.equal(r.status, 0, r.stderr);
		const log = readFileSync(join(base, 'logs', 'check-collector.log'), 'utf8');
		assert.match(log, /✅ 正常/, log);
		assert.doesNotMatch(log, /DB を読めません/, log);
	} finally {
		rmSync(base, { recursive: true, force: true });
	}
});

test('ログの日時（JST）を読める', () => {
	assert.equal(parseLogTimestamp('2026/10/04 22:00:01.500 ⚠️ 再確認待ち x'), jst('2026-10-04T22:00:01.500'));
	assert.equal(parseLogTimestamp('日時ではない行'), null);
});

test('前回が「再確認待ち」か「異常」で、30 分以内なら、続けて異常（通知する）', () => {
	const now = jst('2026-10-04T22:10:00');
	assert.equal(confirmedAgain('2026/10/04 22:00:00.000 ⚠️ 再確認待ち x', now), true);
	assert.equal(confirmedAgain('2026/10/04 22:00:00.000 ❌ 異常 x', now), true);
});

test('前回が正常、古すぎる、または無いときは、最初の異常として扱う（通知しない）', () => {
	const now = jst('2026-10-04T22:10:00');
	assert.equal(confirmedAgain('2026/10/04 22:00:00.000 ✅ 正常 x', now), false);
	assert.equal(confirmedAgain('2026/10/04 21:00:00.000 ⚠️ 再確認待ち x', now), false);
	assert.equal(confirmedAgain(undefined, now), false);
});
