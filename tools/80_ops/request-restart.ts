// 収集サービスに、再起動を依頼する（管理者は要らない）。受信箱（_data/request/inbox）にファイルを置き、
// サービスが受け取って、終了コード 75 で終わり、winsw が新しい exe で起動し直すまでを待つ。
// 引数（すべて任意）
//   base:<パス>     DB・受信箱の置き場（省略時はプロジェクトのルート）
//   note:<理由>     依頼の理由（200 文字まで）
//   timeout:<秒>    結果を待つ長さ（既定 60）
// 終了コード 0 は完了、1 は失敗または時間切れ、2 は引数の誤り
import { join } from 'node:path';
import { requestRestart } from './lib/request.ts';

const argv = process.argv.slice(2);
const arg = (key: string): string | undefined => {
	const a = argv.find((x) => x.toLowerCase().startsWith(key + ':'));
	return a?.slice(key.length + 1);
};

const base = arg('base') ?? join(import.meta.dirname, '..', '..');
const note = arg('note');
const timeoutSec = Number(arg('timeout') ?? '60');
if (!Number.isFinite(timeoutSec) || timeoutSec <= 0) {
	console.log(`❌ timeout: には、1 以上の秒数を書いてください: ${arg('timeout')}`);
	process.exit(2);
}
if (note !== undefined && [...note].length > 200) {
	console.log('❌ note: は 200 文字までです');
	process.exit(2);
}

console.log('再起動を依頼します...');
const r = await requestRestart(base, { note, timeoutMs: timeoutSec * 1000 });
console.log(`${r.ok ? '✅ 完了' : r.status === 'timeout' ? '⏱️ 時間切れ' : '❌ 失敗'}: ${r.detail}（${r.name}）`);
process.exit(r.ok ? 0 : 1);
