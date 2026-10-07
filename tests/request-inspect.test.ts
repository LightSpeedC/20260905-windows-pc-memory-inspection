import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { formatInspect, inspectArgError, requestInspect } from '../tools/80_ops/lib/request.ts';

const jst = (s: string): Date => new Date(s + '+09:00');
const GB = 1024 ** 3;

function setup(): { base: string; dir: (n: string) => string; done: () => void } {
	const base = mkdtempSync(join(tmpdir(), 'req-inspect-'));
	const root = join(base, '_data', 'request');
	for (const n of ['inbox', 'proc', 'comp', 'error']) mkdirSync(join(root, n), { recursive: true });
	return { base, dir: (n) => join(root, n), done: () => rmSync(base, { recursive: true, force: true }) };
}

// サービスの代わりに、受信箱の依頼を完了へ移す
function fakeService(t: ReturnType<typeof setup>, body: object, to: 'comp' | 'error' = 'comp'): NodeJS.Timeout {
	return setInterval(() => {
		for (const name of readdirSync(t.dir('inbox'))) {
			if (!name.endsWith('.json')) continue;
			renameSync(join(t.dir('inbox'), name), join(t.dir('proc'), name));
			writeFileSync(join(t.dir(to), name), JSON.stringify(body));
		}
	}, 20);
}

const RESULT = {
	status: 'completed',
	version: '9.9.9',
	completed_at: '2026/10/07 12:30:00.000',
	result: {
		sort: 'commit',
		process_count: 3,
		processes: [
			{ pid: 3592, process_name: 'llama-server', commit_bytes: 6.3 * GB, working_set_bytes: 6.2 * GB, started_at: '2026/10/07 12:24:53.000', parent_pid: 100 },
			{ pid: 30, process_name: 'unreadable.exe', commit_bytes: null, working_set_bytes: null, started_at: '2026/10/07 09:00:00.000', parent_pid: null },
		],
		system: { phys_total: 32 * GB, phys_avail: 7.4 * GB, commit_limit: 56.7 * GB, commit_used: 54.3 * GB, pagefile_used: 1.7 * GB, pagefile_peak: null },
	},
};

test('依頼の中身は action・top・sort・note。指定しなかったものは書かない', async () => {
	const t = setup();
	try {
		await requestInspect(t.base, { now: jst('2026-10-07T12:30:00'), timeoutMs: 50, pollMs: 10, top: 5, sort: 'working_set', note: '急増の調査' });
		const files = readdirSync(t.dir('inbox'));
		assert.deepEqual(files, ['req-20261007-123000.json'], '.tmp が残っている');
		assert.deepEqual(JSON.parse(readFileSync(join(t.dir('inbox'), files[0]!), 'utf8')), { action: 'inspect', top: 5, sort: 'working_set', note: '急増の調査' });
	} finally {
		t.done();
	}
});

test('引数を省くと、動作だけを書く（既定は収集の側が決める）', async () => {
	const t = setup();
	try {
		await requestInspect(t.base, { now: jst('2026-10-07T12:30:00'), timeoutMs: 50, pollMs: 10 });
		const files = readdirSync(t.dir('inbox'));
		assert.deepEqual(JSON.parse(readFileSync(join(t.dir('inbox'), files[0]!), 'utf8')), { action: 'inspect' });
	} finally {
		t.done();
	}
});

test('完了したら、結果（プロセスとシステム全体の値）を返す', async () => {
	const t = setup();
	const timer = fakeService(t, RESULT);
	try {
		const r = await requestInspect(t.base, { now: jst('2026-10-07T12:30:00'), timeoutMs: 3000, pollMs: 20 });
		assert.equal(r.ok, true);
		assert.equal((r.result as { process_count: number }).process_count, 3);
	} finally {
		clearInterval(timer);
		t.done();
	}
});

test('失敗したら、理由を付けて失敗を返す', async () => {
	const t = setup();
	const timer = fakeService(t, { status: 'error', reason: 'top は 1〜100 の整数です' }, 'error');
	try {
		const r = await requestInspect(t.base, { now: jst('2026-10-07T12:30:00'), timeoutMs: 3000, pollMs: 20 });
		assert.equal(r.ok, false);
		assert.match(r.detail, /top は/);
	} finally {
		clearInterval(timer);
		t.done();
	}
});

test('サービスが動いていなければ、時間切れを返す', async () => {
	const t = setup();
	try {
		const r = await requestInspect(t.base, { now: jst('2026-10-07T12:30:00'), timeoutMs: 100, pollMs: 20 });
		assert.equal(r.status, 'timeout');
	} finally {
		t.done();
	}
});

test('表示は、GB の小数 2 桁。読めなかった値は - で、0 と書かない', () => {
	const text = formatInspect(RESULT.result);
	assert.match(text, /llama-server/);
	assert.match(text, /6\.30/, 'コミットが GB で出ない');
	const unreadable = text.split('\n').find((l) => l.includes('unreadable.exe'))!;
	assert.match(unreadable, /-/);
	assert.doesNotMatch(unreadable, /0\.00/, '読めなかった値を 0 と書いた');
});

test('表示に、システム全体の値（空き・コミットと上限）を含める', () => {
	const text = formatInspect(RESULT.result);
	assert.match(text, /54\.30/);
	assert.match(text, /56\.70/);
	assert.match(text, /7\.40/);
});

test('引数の検査: top は 1〜100 の整数、sort は commit か working_set', () => {
	assert.equal(inspectArgError({ top: '20', sort: 'commit' }), null);
	assert.equal(inspectArgError({}), null);
	assert.match(inspectArgError({ top: '0' })!, /top/);
	assert.match(inspectArgError({ top: '101' })!, /top/);
	assert.match(inspectArgError({ top: 'x' })!, /top/);
	assert.match(inspectArgError({ top: '1.5' })!, /top/);
	assert.match(inspectArgError({ sort: 'cpu' })!, /sort/);
});
