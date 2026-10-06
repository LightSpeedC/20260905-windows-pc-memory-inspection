import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildClaudeArgs, parseArgs } from '../tools/80_ops/lib/args.ts';

test('引数が無いときは、すべて既定（待つ・AI あり・モデル指定なし）', () => {
	assert.deepEqual(parseArgs([]), { nopause: false, noai: false, model: undefined, effort: undefined });
});

test('nopause・noai は大小文字を区別せず、順番も問わない', () => {
	const a = parseArgs(['NoAI', 'NOPAUSE']);
	assert.equal(a.nopause, true);
	assert.equal(a.noai, true);
});

test('model:・effort: は : で区切って値を取る（= ではなく : を使う理由は cmd の引数割れ）', () => {
	const a = parseArgs(['model:sonnet', 'effort:high']);
	assert.equal(a.model, 'sonnet');
	assert.equal(a.effort, 'high');
});

test('値が空の model: は指定なしとして扱う', () => {
	assert.equal(parseArgs(['model:']).model, undefined);
});

test('知らない引数は無視する', () => {
	const a = parseArgs(['xyz', 'nopause']);
	assert.equal(a.nopause, true);
});

test('claude へ渡す引数は、モデル・effort（指定時のみ）→ -p → 指示文の順', () => {
	assert.deepEqual(buildClaudeArgs('r.html', {}), [
		'-p',
		'r.html に、inspect-process-memory-observations.md の内容を踏まえて考察（ch06）を追加して',
	]);
	assert.deepEqual(buildClaudeArgs('r.html', { model: 'sonnet', effort: 'high' }).slice(0, 5), [
		'--model',
		'sonnet',
		'--effort',
		'high',
		'-p',
	]);
});
