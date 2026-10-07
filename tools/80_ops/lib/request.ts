// 収集サービスへの依頼（再起動・プロセスの状態の調査）を、受信箱のファイルで出す。
// 流れ: inbox/req-….tmp に書く → 書き終えたら .json へ名前を変える（書きかけを読ませない）
//       → サービスが受け取って proc/ → 結果が comp/（完了）か error/（失敗）に出る
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const JST_OFFSET_MS = 9 * 3_600_000;

export interface RequestResult {
	ok: boolean;
	status: 'completed' | 'error' | 'timeout';
	// 人が読む説明（完了なら新しい版と時刻、失敗なら理由）
	detail: string;
	// 依頼のファイル名（req-….json）
	name: string;
}

export interface RequestOptions {
	note?: string;
	// 結果を待つ長さ。省略時は 60 秒
	timeoutMs?: number;
	pollMs?: number;
	// ファイル名に使う時刻（試験用。省略時は現在）
	now?: Date;
}

// req-yyyymmdd-hhmmss（JST）。同じ名前がすでにあれば、末尾に -2・-3 … を足す
export function requestFileStem(now: Date, isTaken: (stem: string) => boolean): string {
	const jst = new Date(now.getTime() + JST_OFFSET_MS).toISOString(); // 2026-10-06T23:37:00.000Z（JST の時刻を UTC として読む）
	const base = 'req-' + jst.slice(0, 10).replaceAll('-', '') + '-' + jst.slice(11, 19).replaceAll(':', '');
	if (!isTaken(base)) return base;
	for (let i = 2; ; i++) {
		if (!isTaken(`${base}-${i}`)) return `${base}-${i}`;
	}
}

function readJson(path: string): Record<string, unknown> | null {
	try {
		return JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
	} catch {
		return null;
	}
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export async function requestRestart(baseDir: string, options: RequestOptions = {}): Promise<RequestResult> {
	const body: Record<string, unknown> = { action: 'restart' };
	if (options.note) body.note = options.note;
	const r = await submitRequest(baseDir, body, options);
	return r.status === 'completed' ? { ...r, detail: `新しい版 v${String(r.response?.version)}、完了 ${String(r.response?.completed_at)}` } : r;
}

export interface InspectOptions extends RequestOptions {
	// 上位の件数（1〜100）。省略時は収集の側の既定（20）
	top?: number;
	// commit（既定）か working_set
	sort?: string;
}

export interface InspectResult extends RequestResult {
	// 収集が書いた結果（完了のときだけ）
	result?: InspectData;
}

export interface InspectData {
	sort?: string;
	process_count?: number;
	processes: Array<{
		pid: number;
		process_name: string;
		commit_bytes: number | null;
		working_set_bytes: number | null;
		started_at: string;
		parent_pid: number | null;
	}>;
	system: Record<string, number | null>;
}

// 依頼の引数の検査。誤りなら、利用者に見せる説明を返す（収集の側も同じ範囲で検査する）
export function inspectArgError(args: { top?: string; sort?: string }): string | null {
	if (args.top !== undefined && !/^[0-9]+$/.test(args.top)) return 'top: には、1〜100 の整数を書いてください';
	if (args.top !== undefined && (Number(args.top) < 1 || Number(args.top) > 100)) return 'top: には、1〜100 の整数を書いてください';
	if (args.sort !== undefined && args.sort !== 'commit' && args.sort !== 'working_set') return 'sort: には、commit か working_set を書いてください';
	return null;
}

// いまのプロセスの状態（コミットの大きい上位 N 件とシステム全体の値）を、収集に調べさせる
export async function requestInspect(baseDir: string, options: InspectOptions = {}): Promise<InspectResult> {
	const body: Record<string, unknown> = { action: 'inspect' };
	if (options.top !== undefined) body.top = options.top;
	if (options.sort !== undefined) body.sort = options.sort;
	if (options.note) body.note = options.note;
	const r = await submitRequest(baseDir, body, options);
	if (r.status !== 'completed') return r;
	return { ...r, detail: `完了 ${String(r.response?.completed_at)}`, result: r.response?.result as InspectData | undefined };
}

const gb = (n: number | null | undefined): string => (n === null || n === undefined ? '-' : (n / 1024 ** 3).toFixed(2));

// 結果を表にする。読めなかった値は - （0 と書かない）。コマンドラインは、そもそも結果に入っていない
export function formatInspect(d: InspectData): string {
	const s = d.system;
	const lines = [
		`システム全体（GB）: 物理 ${gb(s.phys_total)} / 空き ${gb(s.phys_avail)} / コミット ${gb(s.commit_used)}（上限 ${gb(s.commit_limit)}）/ ページファイル使用 ${gb(s.pagefile_used)}（ピーク ${gb(s.pagefile_peak)}）`,
		`上位 ${d.processes.length} 件（全 ${String(d.process_count ?? '?')} 件、並び順 ${String(d.sort ?? 'commit')}）`,
		'  pid  コミット(GB)  作業セット(GB)  起動                     名前',
	];
	for (const p of d.processes) {
		lines.push(`${String(p.pid).padStart(6)}  ${gb(p.commit_bytes).padStart(11)}  ${gb(p.working_set_bytes).padStart(13)}  ${p.started_at.slice(0, 19)}  ${p.process_name}`);
	}
	return lines.join('\n');
}

interface Submitted extends RequestResult {
	// 完了のときの、comp/ のファイルの中身
	response?: Record<string, unknown>;
}

async function submitRequest(baseDir: string, body: Record<string, unknown>, options: RequestOptions): Promise<Submitted> {
	const root = join(baseDir, '_data', 'request');
	const dir = (n: string): string => join(root, n);
	for (const n of ['inbox', 'proc', 'comp', 'error']) mkdirSync(dir(n), { recursive: true });

	const stem = requestFileStem(options.now ?? new Date(), (s) =>
		['inbox', 'proc', 'comp', 'error'].some((n) => existsSync(join(dir(n), `${s}.json`)) || existsSync(join(dir(n), `${s}.tmp`))),
	);
	const name = `${stem}.json`;

	// .tmp に書き、書き終えてから名前を変える
	writeFileSync(join(dir('inbox'), `${stem}.tmp`), JSON.stringify(body));
	renameSync(join(dir('inbox'), `${stem}.tmp`), join(dir('inbox'), name));

	const timeoutMs = options.timeoutMs ?? 60_000;
	const pollMs = options.pollMs ?? 250;
	const start = Date.now();
	while (Date.now() - start <= timeoutMs) {
		const done = readJson(join(dir('comp'), name));
		if (done) {
			return { ok: true, status: 'completed', name, detail: '完了', response: done };
		}
		const failed = readJson(join(dir('error'), name));
		if (failed) {
			return { ok: false, status: 'error', name, detail: String(failed.reason ?? '理由が書かれていません') };
		}
		await sleep(pollMs);
	}
	return { ok: false, status: 'timeout', name, detail: `${Math.round(timeoutMs / 1000)} 秒待っても、結果が出ません（サービスが動いていない可能性があります）` };
}
