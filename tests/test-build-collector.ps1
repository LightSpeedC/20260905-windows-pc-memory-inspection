# build-collector.ps1 の、exe の置き替え（Set-ExeFile）の回帰テスト。
# サービスが動いている間は、deploy/ の exe が掴まれていて、上書きも削除もできない。
# Windows は、実行中の exe の名前を変える（退避する）ことはできるので、退避してから新しい exe を置く。
# 動いている旧い exe は、そのまま動き続ける（サービスの再起動で、新しい exe に切り替わる）。

$ErrorActionPreference = 'Stop'

$target = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/20_build/build-collector.ps1'
if (-not (Test-Path -LiteralPath $target)) {
	Write-Host ('対象が見つからない: ' + $target)
	exit 1
}

# 関数の定義だけを切り出す（スクリプトを実行すると、ビルドが走ってしまうため）
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Set-ExeFile' }, $true)
if (-not $fn) {
	Write-Host '切り出す関数 Set-ExeFile が見つからない。テストの側を直す'
	exit 1
}
Invoke-Expression $fn.Extent.Text

$ng = 0
function Test-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
	if ($Ok) {
		Write-Host ('  OK   ' + $Name)
	} else {
		Write-Host ('  NG   ' + $Name + $(if ($Detail) { '（' + $Detail + '）' }))
		$script:ng++
	}
}

$work = Join-Path (Split-Path -Parent $PSScriptRoot) ('tmp/test-build-' + [guid]::NewGuid().ToString('N'))
$deploy = Join-Path $work 'deploy'
$old = Join-Path $work 'old'
New-Item -ItemType Directory -Force -Path $deploy | Out-Null
$proc = $null
try {
	$dest = Join-Path $deploy 'rust-ai-pc-memory-collector.exe'
	$ping = Join-Path $env:SystemRoot 'System32/PING.EXE'
	$built = Join-Path $work 'built.exe'
	Copy-Item -LiteralPath $ping -Destination $built

	Write-Host 'Set-ExeFile'

	# 1. 置き先に何も無いとき
	Set-ExeFile $built $dest $old
	Test-Check '置き先に何も無いときは、そのまま置く' (Test-Path -LiteralPath $dest)

	# 2. 置き先の exe が動いている（掴まれている）とき。実際のサービスと同じ状態を作る
	$proc = Start-Process -FilePath $dest -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru
	Start-Sleep -Milliseconds 500
	$locked = $false
	try { Remove-Item -LiteralPath $dest -Force -ErrorAction Stop } catch { $locked = $true }
	Test-Check '前提: 動いている exe は、削除できない（掴まれている）' $locked

	# 新しい exe は、見分けがつくように、内容を変えておく
	[System.IO.File]::AppendAllText($built, 'x')
	$newLength = (Get-Item -LiteralPath $built).Length
	Set-ExeFile $built $dest $old
	Test-Check '掴まれていても、新しい exe を置ける' ((Get-Item -LiteralPath $dest).Length -eq $newLength)
	$moved = @(Get-ChildItem -LiteralPath $old -Filter 'rust-ai-pc-memory-collector-old-*.exe' -File)
	Test-Check '動いていた exe は、退避先に残っている' ($moved.Count -eq 1)
	Test-Check '動いていた exe は、そのまま動き続ける' (-not $proc.HasExited)

	# 3. 前回までに退避して、もう掴まれていないものは、次の置き替えで消える
	$proc | Stop-Process -Force
	$proc.WaitForExit()
	Start-Sleep -Milliseconds 300
	Set-ExeFile $built $dest $old
	$left = @(Get-ChildItem -LiteralPath $old -Filter 'rust-ai-pc-memory-collector-old-*.exe' -File)
	Test-Check '掴まれなくなった前回の退避は、消える（退避先に溜まらない）' ($left.Count -eq 1) ('退避先に ' + $left.Count + ' 個ある')
} finally {
	if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force; $proc.WaitForExit() }
	Start-Sleep -Milliseconds 300
	Remove-Item -LiteralPath $work -Recurse -Force
}

# -Restart を付けると、置き替えのあとに、再起動を依頼する（管理者は要らない）。依頼の道具が実在すること
Write-Host '-Restart（再起動の依頼）'
$text = [System.IO.File]::ReadAllText($target)
if ($text -match '\[switch\]\$Restart') {
	Write-Host '  OK   -Restart の引数がある'
} else {
	Write-Host '  NG   -Restart の引数が無い'
	$ng++
}
if ($text -match 'request-restart\.ts') {
	$tool = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/80_ops/request-restart.ts'
	if (Test-Path -LiteralPath $tool) {
		Write-Host '  OK   再起動の依頼の道具を呼び、その道具が実在する'
	} else {
		Write-Host '  NG   呼んでいる道具が実在しない: tools/80_ops/request-restart.ts'
		$ng++
	}
} else {
	Write-Host '  NG   再起動の依頼の道具（request-restart.ts）を呼んでいない'
	$ng++
}

if ($ng -eq 0) {
	Write-Host '結果: すべて通った'
} else {
	Write-Host ('結果: ' + $ng + ' 件 失敗')
}
exit $ng
