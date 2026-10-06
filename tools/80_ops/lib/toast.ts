import { spawnSync } from 'node:child_process';

export function escapeXml(s: string): string {
	return s
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;')
		.replaceAll("'", '&apos;');
}

// -EncodedCommand は UTF-16LE の Base64。コードページに依存せず、日本語をそのまま渡せる
export function encodePowerShell(script: string): string {
	return Buffer.from(script, 'utf16le').toString('base64');
}

// 本体のクリックと「ログを開く」ボタンの両方で、uri（ログ）を開く
export function buildToastScript(title: string, body: string, uri: string): string {
	const u = escapeXml(uri);
	const xml =
		`<toast activationType="protocol" launch="${u}"><visual><binding template="ToastGeneric">` +
		`<text>${escapeXml(title)}</text><text>${escapeXml(body)}</text></binding></visual>` +
		`<actions><action content="ログを開く" activationType="protocol" arguments="${u}"/></actions></toast>`;
	return [
		"[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null",
		"[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null",
		"$xml = New-Object Windows.Data.Xml.Dom.XmlDocument",
		`$xml.LoadXml('${xml}')`,
		"$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)",
		"$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'",
		"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)",
	].join('\n');
}

// Windows PowerShell 5.1 でトーストを出す。終了コードを返す
export function showToast(title: string, body: string, uri: string): number {
	const script = buildToastScript(title, body, uri);
	const r = spawnSync(
		'powershell',
		['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encodePowerShell(script)],
		{ stdio: 'ignore', timeout: 30_000 },
	);
	return r.status ?? 1;
}
