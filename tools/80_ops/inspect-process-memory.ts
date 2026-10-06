// 全プロセスのメモリ調査を行い、logs へ HTML レポートを出力したあと、claude に考察を書き足させる。
// タスクスケジューラが指す inspect-process-memory.cmd から呼ばれる。実行の経過は logs/task-run.log に UTF-8 で残す。
//
// 引数（順番は問わない。大小文字は区別しない）
//   nopause      実行後にキー入力を待たない。昇格もブラウザ表示もしない
//   noai         claude による考察の追記を行わない
//   model:<名前>  考察に使うモデルを指定する（省略時はアカウントの既定）
//   effort:<値>   考察の思考の深さを指定する（省略時は既定）
import { spawnSync } from 'node:child_process';
import { closeSync, existsSync, openSync, readFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { buildClaudeArgs, parseArgs } from './lib/args.ts';
import { appendLog } from './lib/log.ts';

const root = join(import.meta.dirname, '..', '..');
const logFile = join(root, 'logs', 'task-run.log');
const log = (message: string): void => appendLog(logFile, message);

const MINUTE = 60_000;
const args = parseArgs(process.argv.slice(2));

async function main(): Promise<number> {
	log(`開始 引数: ${process.argv.slice(2).join(' ')}`);

	// subst で割り当てた W ドライブは別のログオンセッションからは見えないため、
	// 接続先をシステム環境変数から読んで張り直す。二重に張ると Drive already SUBSTed になるため、存在を見てから張る
	const substTarget = process.env._SECRET_SUBST_W_DRIVE;
	if (!substTarget) {
		console.log('環境変数 _SECRET_SUBST_W_DRIVE が設定されていません。');
		log('中断: 環境変数 _SECRET_SUBST_W_DRIVE が設定されていません');
		return 1;
	}
	if (!existsSync('W:/')) spawnSync('subst', ['W:', substTarget], { stdio: 'ignore', timeout: MINUTE });

	const projectDir = `W:/2026/${basename(root)}`;
	try {
		process.chdir(projectDir);
	} catch {
		console.log('W ドライブへ移動できませんでした。');
		log('中断: W ドライブへ移動できませんでした');
		return 1;
	}

	// タスクスケジューラからは昇格の確認ダイアログを出せないので、nopause では自己昇格を止める。
	// 管理者で動かしたい場合はタスク側で「最上位の特権で実行する」を有効にする。
	// ps1 の出力は受けず画面に出す（受けると CP932 になり、ログの文字コードが混ざる）。終了コードだけ見る
	log('ps1 を実行します');
	const ps1 = spawnSync(
		'powershell',
		['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools/80_ops/inspect-process-memory.ps1', args.nopause ? '-NoElevate' : '-Open'],
		{ stdio: 'inherit', timeout: 10 * MINUTE },
	);
	let rc = ps1.status ?? 1;
	log(`ps1 終了コード: ${rc}`);

	if (args.noai) return rc;

	// ps1 が書き残した直近の出力を読む
	const lastReport = 'logs/last-report.txt';
	const report = existsSync(lastReport) ? readFileSync(lastReport, 'utf8').replace(/^\uFEFF/, '').trim() : '';
	if (!report || !existsSync(report)) {
		console.log('レポートが見つかりませんでした。');
		log('中断: レポートが見つかりませんでした');
		return 1;
	}

	console.log(`考察を追記します: ${report}`);
	console.log(`モデル: ${args.model ? args.model + '（指定）' : '既定'}`);
	console.log(`effort: ${args.effort ? args.effort + '（指定）' : '既定'}`);
	console.log('---- 観点ファイルの内容 ----');
	console.log(readFileSync('inspect-process-memory-observations.md', 'utf8'));
	console.log('-----------------------------');
	console.log('この処理は数分（実測で5分程度）かかることがあります。画面に何も出なくても止まっていません。そのままお待ちください。');

	// 実行アカウントの PATH で claude.exe・node が見つかるかを残す
	for (const name of ['claude.exe', 'node']) {
		const where = spawnSync('where', [name], { encoding: 'buffer', timeout: MINUTE });
		if (where.status !== 0) {
			log(`${name} が PATH に見つかりません`);
			continue;
		}
		for (const line of new TextDecoder('shift_jis').decode(where.stdout).split(/\r?\n/).filter(Boolean)) {
			log(`${name} の場所: ${line}`);
		}
	}

	// claude の出力（UTF-8）は、同じログへそのまま書く。ラッパーの claude.cmd を経由しないよう claude.exe を直接呼ぶ
	log('claude -p を実行します');
	const fd = openSync(logFile, 'a');
	const claude = spawnSync('claude.exe', buildClaudeArgs(report, args), {
		stdio: ['ignore', fd, fd],
		timeout: 30 * MINUTE,
	});
	closeSync(fd);
	if (claude.error) log(`claude.exe を起動できませんでした: ${claude.error.message}`);
	rc = claude.status ?? 1;
	log(`claude -p 終了コード: ${rc}`);
	return rc;
}

const rc = await main();
log(`終了 終了コード: ${rc}`);
if (!args.nopause) {
	console.log('Enter キーで終了します');
	await new Promise<void>((resolve) => process.stdin.once('data', () => resolve()));
}
process.exit(rc);
