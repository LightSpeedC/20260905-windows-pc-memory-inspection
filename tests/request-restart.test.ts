import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { requestFileStem, requestRestart } from '../tools/80_ops/lib/request.ts';

const jst = (s: string): Date => new Date(s + '+09:00');

function setup(): { base: string; dir: (n: string) => string; done: () => void } {
	const base = mkdtempSync(join(tmpdir(), 'req-restart-'));
	const root = join(base, '_data', 'request');
	for (const n of ['inbox', 'proc', 'comp', 'error']) mkdirSync(join(root, n), { recursive: true });
	return { base, dir: (n) => join(root, n), done: () => rmSync(base, { recursive: true, force: true }) };
}

test('依頼のファイル名は req-yyyymmdd-hhmmss（JST）', () => {
	assert.equal(requestFileStem(jst('2026-10-06T23:37:00'), () => false), 'req-20261006-233700');
	// UTC では日付が違う時刻でも、JST で書く
	assert.equal(requestFileStem(new Date('2026-10-06T15:37:00Z'), () => false), 'req-20261007-003700');
});

test('同じ秒に 2 件出すときは、末尾に連番を足す', () => {
	const taken = new Set(['req-20261006-233700', 'req-20261006-233700-2']);
	assert.equal(requestFileStem(jst('2026-10-06T23:37:00'), (s) => taken.has(s)), 'req-20261006-233700-3');
});

test('依頼を出すと、受信箱に .json ができ、.tmp は残らない', async () => {
	const t = setup();
	try {
		await requestRestart(t.base, { now: jst('2026-10-06T23:37:00'), timeoutMs: 50, pollMs: 10, note: '置き替えた' });
		const files = readdirSync(t.dir('inbox'));
		assert.deepEqual(files, ['req-20261006-233700.json']);
		const body = JSON.parse(readFileSync(join(t.dir('inbox'), files[0]!), 'utf8'));
		assert.deepEqual(body, { action: 'restart', note: '置き替えた' });
	} finally {
		t.done();
	}
});

// サービスの代わりに、受信箱の依頼を完了へ移す
function fakeService(t: ReturnType<typeof setup>, result: object): NodeJS.Timeout {
	return setInterval(() => {
		for (const name of readdirSync(t.dir('inbox'))) {
			if (!name.endsWith('.json')) continue;
			const status = (result as { status: string }).status;
			renameSync(join(t.dir('inbox'), name), join(t.dir('proc'), name));
			writeFileSync(join(t.dir(status === 'completed' ? 'comp' : 'error'), name), JSON.stringify(result));
		}
	}, 20);
}

test('完了に移ったら、新しい版を付けて成功を返す', async () => {
	const t = setup();
	const timer = fakeService(t, { status: 'completed', version: '9.9.9', completed_at: '2026/10/06 23:37:12.000' });
	try {
		const r = await requestRestart(t.base, { now: jst('2026-10-06T23:37:00'), timeoutMs: 3000, pollMs: 20 });
		assert.equal(r.ok, true);
		assert.equal(r.status, 'completed');
		assert.match(r.detail, /9\.9\.9/);
	} finally {
		clearInterval(timer);
		t.done();
	}
});

test('失敗に移ったら、理由を付けて失敗を返す', async () => {
	const t = setup();
	const timer = fakeService(t, { status: 'error', reason: '知らない動作です: x' });
	try {
		const r = await requestRestart(t.base, { now: jst('2026-10-06T23:37:00'), timeoutMs: 3000, pollMs: 20 });
		assert.equal(r.ok, false);
		assert.equal(r.status, 'error');
		assert.match(r.detail, /知らない動作/);
	} finally {
		clearInterval(timer);
		t.done();
	}
});

test('サービスが動いていなければ、時間切れを返す（依頼のファイルは受信箱に残る）', async () => {
	const t = setup();
	try {
		const r = await requestRestart(t.base, { now: jst('2026-10-06T23:37:00'), timeoutMs: 150, pollMs: 20 });
		assert.equal(r.ok, false);
		assert.equal(r.status, 'timeout');
		assert.equal(existsSync(join(t.dir('inbox'), 'req-20261006-233700.json')), true);
	} finally {
		t.done();
	}
});
