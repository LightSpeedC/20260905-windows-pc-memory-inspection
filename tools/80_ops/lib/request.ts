// 収集サービスへの依頼（再起動）を、受信箱のファイルで出す。
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
	const root = join(baseDir, '_data', 'request');
	const dir = (n: string): string => join(root, n);
	for (const n of ['inbox', 'proc', 'comp', 'error']) mkdirSync(dir(n), { recursive: true });

	const stem = requestFileStem(options.now ?? new Date(), (s) =>
		['inbox', 'proc', 'comp', 'error'].some((n) => existsSync(join(dir(n), `${s}.json`)) || existsSync(join(dir(n), `${s}.tmp`))),
	);
	const name = `${stem}.json`;
	const body: Record<string, string> = { action: 'restart' };
	if (options.note) body.note = options.note;

	// .tmp に書き、書き終えてから名前を変える
	writeFileSync(join(dir('inbox'), `${stem}.tmp`), JSON.stringify(body));
	renameSync(join(dir('inbox'), `${stem}.tmp`), join(dir('inbox'), name));

	const timeoutMs = options.timeoutMs ?? 60_000;
	const pollMs = options.pollMs ?? 250;
	const start = Date.now();
	while (Date.now() - start <= timeoutMs) {
		const done = readJson(join(dir('comp'), name));
		if (done) {
			return { ok: true, status: 'completed', name, detail: `新しい版 v${String(done.version)}、完了 ${String(done.completed_at)}` };
		}
		const failed = readJson(join(dir('error'), name));
		if (failed) {
			return { ok: false, status: 'error', name, detail: String(failed.reason ?? '理由が書かれていません') };
		}
		await sleep(pollMs);
	}
	return { ok: false, status: 'timeout', name, detail: `${Math.round(timeoutMs / 1000)} 秒待っても、結果が出ません（サービスが動いていない可能性があります）` };
}
