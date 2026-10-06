export interface Args {
	nopause: boolean;
	noai: boolean;
	model: string | undefined;
	effort: string | undefined;
}

// = ではなく : で区切る。cmd が = を引数の区切りとして扱うため、model=sonnet が割れる
export function parseArgs(argv: string[]): Args {
	const args: Args = { nopause: false, noai: false, model: undefined, effort: undefined };
	for (const a of argv) {
		const lower = a.toLowerCase();
		if (lower === 'nopause') args.nopause = true;
		else if (lower === 'noai') args.noai = true;
		else if (lower.startsWith('model:')) args.model = a.slice('model:'.length) || undefined;
		else if (lower.startsWith('effort:')) args.effort = a.slice('effort:'.length) || undefined;
	}
	return args;
}

export function buildClaudeArgs(report: string, options: { model?: string; effort?: string }): string[] {
	const out: string[] = [];
	if (options.model) out.push('--model', options.model);
	if (options.effort) out.push('--effort', options.effort);
	out.push('-p', `${report} に、inspect-process-memory-observations.md の内容を踏まえて考察（ch06）を追加して`);
	return out;
}
