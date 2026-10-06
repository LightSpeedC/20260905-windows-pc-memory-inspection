import { appendFileSync } from 'node:fs';

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

const pad = (n: number, width = 2): string => String(n).padStart(width, '0');

// 実行環境のタイムゾーンに関係なく JST で書く
export function formatTimestamp(d: Date): string {
	const j = new Date(d.getTime() + JST_OFFSET_MS);
	return (
		`${j.getUTCFullYear()}/${pad(j.getUTCMonth() + 1)}/${pad(j.getUTCDate())} ` +
		`${pad(j.getUTCHours())}:${pad(j.getUTCMinutes())}:${pad(j.getUTCSeconds())}.${pad(j.getUTCMilliseconds(), 3)}`
	);
}

// ログの行頭の日時（JST）を、エポック（ミリ秒）で返す。日時で始まらない行は null
export function parseLogTimestamp(line: string): number | null {
	const m = /^(\d{4})\/(\d{2})\/(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})/.exec(line);
	if (!m) return null;
	const [y, mo, d, h, mi, s, ms] = m.slice(1).map(Number) as [number, number, number, number, number, number, number];
	return Date.UTC(y, mo - 1, d, h, mi, s, ms) - JST_OFFSET_MS;
}

const escapeRegExp = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function maskProfile(text: string, profile: string): string {
	if (!profile) return text;
	let out = text;
	for (const variant of [profile, profile.replaceAll('\\', '/')]) {
		out = out.replace(new RegExp(escapeRegExp(variant), 'gi'), '~');
	}
	return out;
}

export interface LogOptions {
	now?: Date;
	profile?: string;
}

// UTF-8（BOM なし）で 1 行追記する。ユーザープロファイルのパスは ~ に置き換える
export function appendLog(file: string, message: string, options: LogOptions = {}): void {
	const now = options.now ?? new Date();
	const profile = options.profile ?? process.env.USERPROFILE ?? '';
	appendFileSync(file, `${formatTimestamp(now)} ${maskProfile(message, profile)}\n`, 'utf8');
}
