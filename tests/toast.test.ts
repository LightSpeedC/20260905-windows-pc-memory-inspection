import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildToastScript, encodePowerShell, escapeXml } from '../tools/80_ops/lib/toast.ts';

test('XML の特殊文字（& < > " \'）をエスケープする', () => {
	assert.equal(escapeXml('<a & "b" \'c\'>'), '&lt;a &amp; &quot;b&quot; &apos;c&apos;&gt;');
});

test('PowerShell へは UTF-16LE の Base64 で渡す（コードページに依存させない）', () => {
	const script = 'Write-Output "日本語"';
	const encoded = encodePowerShell(script);
	assert.equal(Buffer.from(encoded, 'base64').toString('utf16le'), script);
});

test('トーストの文面と「ログを開く」ボタンの URI が、スクリプトに入る', () => {
	const s = buildToastScript('生成漏れ', 'ch06 がありません', 'file:///W:/x/check-report.log');
	assert.match(s, /生成漏れ/);
	assert.match(s, /ch06 がありません/);
	assert.match(s, /ログを開く/);
	assert.match(s, /file:\/\/\/W:\/x\/check-report\.log/);
});

test('文面に特殊文字があっても、XML が壊れない', () => {
	const s = buildToastScript('a<b', 'x & y', 'file:///W:/a&b.log');
	assert.doesNotMatch(s, /<text>a<b<\/text>/);
	assert.match(s, /a&lt;b/);
	assert.match(s, /x &amp; y/);
	assert.match(s, /a&amp;b\.log/);
});
