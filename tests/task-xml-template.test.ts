import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// タスクスケジューラの登録の雛形（ASCII）。登録のスクリプト（register-inspect-task.ps1）は、バッテリーでも起動して止めない設定で作る。
// 雛形が「バッテリーでは起動しない」だったため、10-08 00:00 のレポートが、AC 電源につなぐまで（00:49）、起動しなかった。
const xml = readFileSync(join(import.meta.dirname, '..', 'tools', '80_ops', 'ai-pc-inspect-process-memory.xml'), 'utf8');
const setting = (name: string): string | undefined => new RegExp(`<${name}>([^<]*)</${name}>`).exec(xml)?.[1];

test('雛形は、バッテリー駆動でもタスクを起動する（AC 電源のときだけ、にしない）', () => {
	assert.equal(setting('DisallowStartIfOnBatteries'), 'false');
});

test('雛形は、動作中にバッテリーへ切り替わっても、タスクを止めない', () => {
	assert.equal(setting('StopIfGoingOnBatteries'), 'false');
});

test('雛形は、実行時刻を逃したら、次に起動できるときに実行する', () => {
	assert.equal(setting('StartWhenAvailable'), 'true');
});
