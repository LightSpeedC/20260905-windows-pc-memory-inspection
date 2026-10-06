import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { appendLog, formatTimestamp, maskProfile } from '../tools/80_ops/lib/log.ts';

// 出力先は tmp/（Git 管理外）。本番のログを触らない
const tmpRoot = join(import.meta.dirname, '..', 'tmp');

test('日時は JST の yyyy/mm/dd hh:mm:ss.ccc（ミリ秒3桁）で書く', () => {
	assert.equal(formatTimestamp(new Date('2026-10-04T00:05:06.007Z')), '2026/10/04 09:05:06.007');
});

test('日付をまたぐときも JST で数える（UTC 15:00 以降は翌日）', () => {
	assert.equal(formatTimestamp(new Date('2026-10-03T15:00:00.000Z')), '2026/10/04 00:00:00.000');
});

test('ユーザープロファイルのパスは ~ に置き換える', () => {
	assert.equal(maskProfile('C:\\Users\\user1\\AppData\\x', 'C:\\Users\\user1'), '~\\AppData\\x');
});

test('ユーザープロファイルの置き換えは大小文字を区別しない', () => {
	assert.equal(maskProfile('c:\\users\\USER1\\a', 'C:\\Users\\user1'), '~\\a');
});

test('スラッシュ区切りのユーザープロファイルも ~ に置き換える', () => {
	assert.equal(maskProfile('C:/Users/user1/a', 'C:\\Users\\user1'), '~/a');
});

test('プロファイルが空のときは文字列を変えない', () => {
	assert.equal(maskProfile('abc', ''), 'abc');
});

test('ログは UTF-8（BOM なし）で 1 行ずつ追記し、日本語が化けない', () => {
	mkdirSync(tmpRoot, { recursive: true });
	const dir = mkdtempSync(join(tmpRoot, 'test-log-'));
	try {
		const file = join(dir, 'a.log');
		const now = new Date('2026-10-04T00:05:06.007Z');
		appendLog(file, '開始 引数: nopause', { now, profile: 'C:\\Users\\user1' });
		appendLog(file, 'claude の場所: C:\\Users\\user1\\.local\\bin\\claude.exe', { now, profile: 'C:\\Users\\user1' });
		const bytes = readFileSync(file);
		assert.notEqual(bytes[0], 0xef, 'BOM が付いている');
		assert.equal(
			bytes.toString('utf8'),
			'2026/10/04 09:05:06.007 開始 引数: nopause\n' +
				'2026/10/04 09:05:06.007 claude の場所: ~\\.local\\bin\\claude.exe\n',
		);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
