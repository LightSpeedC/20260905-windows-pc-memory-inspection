// 収集サービスに、いまのプロセスの状態の調査を依頼する（管理者は要らない）。受信箱（_data/request/inbox）にファイルを置き、
// 収集が、依頼の時点のプロセスの一覧を取って、結果を comp/ に書くまでを待ち、上位の一覧を表示する。
// 毎時のスナップショットを待たずに、コミットが急に増えたときの原因を、その場で探すために使う。
// 結果には、コマンドラインも実行ファイルのパスも入らない（資格情報が入りうるため）。
// 引数（すべて任意）
//   base:<パス>     受信箱の置き場（省略時はプロジェクトのルート）
//   top:<件数>      上位の件数（1〜100。既定 20）
//   sort:<順>       commit（既定）か working_set
//   note:<理由>     依頼の理由（200 文字まで）
//   timeout:<秒>    結果を待つ長さ（既定 60）
// 終了コード 0 は完了、1 は失敗または時間切れ、2 は引数の誤り
import { join } from 'node:path';
import { formatInspect, inspectArgError, requestInspect } from './lib/request.ts';

const argv = process.argv.slice(2);
const arg = (key: string): string | undefined => {
	const a = argv.find((x) => x.toLowerCase().startsWith(key + ':'));
	return a?.slice(key.length + 1);
};

const base = arg('base') ?? join(import.meta.dirname, '..', '..');
const note = arg('note');
const top = arg('top');
const sort = arg('sort');
const timeoutSec = Number(arg('timeout') ?? '60');
if (!Number.isFinite(timeoutSec) || timeoutSec <= 0) {
	console.log(`❌ timeout: には、1 以上の秒数を書いてください: ${arg('timeout')}`);
	process.exit(2);
}
if (note !== undefined && [...note].length > 200) {
	console.log('❌ note: は 200 文字までです');
	process.exit(2);
}
const argError = inspectArgError({ top, sort });
if (argError) {
	console.log(`❌ ${argError}`);
	process.exit(2);
}

console.log('プロセスの状態の調査を依頼します...');
const r = await requestInspect(base, { note, top: top === undefined ? undefined : Number(top), sort, timeoutMs: timeoutSec * 1000 });
if (r.ok && r.result) {
	console.log(`✅ ${r.detail}（${r.name}）`);
	console.log(formatInspect(r.result));
	process.exit(0);
}
console.log(`${r.status === 'timeout' ? '⏱️ 時間切れ' : '❌ 失敗'}: ${r.detail}（${r.name}）`);
process.exit(1);
