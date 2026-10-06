<#
.SYNOPSIS
	レポート生成漏れの検知をタスクスケジューラへ登録する。

.DESCRIPTION
	check-report.cmd を、毎日 0:15・0:45・6:15・6:45・12:15・12:45・18:15・18:45（生成の 15 分後と 45 分後）に実行するタスクを作る。
	:15 の異常は「再確認待ち」としてログだけに残し、:45 でもなお異常のときだけ、トースト通知を出す。
	生成漏れのときは、画面右下にトースト通知を出し、logs/check-report.log にも残す。

	【ログオンしているときのみ実行する】
	トースト通知は、ユーザーがログオンしているデスクトップにしか出ない。
	このため、生成タスク（ログオンの有無にかかわらず実行）とは設定を分ける。
	ログオンしていない間はトーストが出ず、ログだけが残る。

	【subst ドライブ】
	タスクスケジューラは別のログオンセッションで動くため W: が見えない。
	登録するパスは実体パスへ直す。

	【収集の検知（-Target collector）】
	check-pc-memory-collector.cmd を 10 分ごとに実行するタスクを作る（メモリの時系列収集が止まっていないかを見る）。
	最初の異常は「再確認待ち」としてログだけに残し、続けて異常のとき（次の 10 分後）だけ、トースト通知を出す。

.PARAMETER Target
	検知の対象。report（既定。レポート生成）か collector（メモリの時系列収集）。

.PARAMETER TaskName
	タスク名。既定は ai-pc-check-report（-Target collector なら ai-pc-check-pc-memory-collector）。

.PARAMETER TaskPath
	タスクの置き場（フォルダ）。既定は生成タスクと同じ \My-Local-Private-PC\。

.PARAMETER CheckArgs
	check-report.cmd へ渡す引数。動作の確認用（例: "now:2026-10-04T23:15:00+09:00" で、その時刻として確認させ、
	異常とトーストを意図的に起こす）。確認用のタスクは -TaskName を変えて登録し、終わったら -Unregister で消す。

.PARAMETER Unregister
	登録を解除する。

.PARAMETER Pause
	終了時にキー入力を待つ。
#>
[CmdletBinding()]
param(
	[ValidateSet('report', 'collector')]
	[string]$Target = 'report',
	[string]$TaskName = 'ai-pc-check-report',
	[string]$TaskPath = '\My-Local-Private-PC\',
	[string]$CheckArgs = '',
	[switch]$Unregister,
	[switch]$Pause
)

$ErrorActionPreference = 'Stop'

if ($Target -eq 'collector' -and -not $PSBoundParameters.ContainsKey('TaskName')) {
	$TaskName = 'ai-pc-check-pc-memory-collector'
}
$cmdName = if ($Target -eq 'collector') { 'check-pc-memory-collector.cmd' } else { 'check-report.cmd' }

# 表示にユーザー名やパスの実体を出さない
function Hide-Name([string]$Text) {
	if ([string]::IsNullOrEmpty($Text)) { return $Text }
	return '<' + $Text.Length + ' 文字>'
}

# subst で割り当てたドライブは別セッションから見えないため、実体パスへ直す
function Resolve-SubstPath([string]$Path) {
	$root = [System.IO.Path]::GetPathRoot($Path)
	if (-not $root) { return $Path }
	$drive = $root.TrimEnd('\')
	if ($drive.Length -ne 2) { return $Path }

	foreach ($line in (subst)) {
		# subst の出力は「W:\: => C:\〈実体フォルダ〉」の形
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if ($m.Success -and $m.Groups[1].Value -eq $drive) {
			return $m.Groups[2].Value + $Path.Substring($drive.Length)
		}
	}
	return $Path
}

function Complete-Script([int]$Code) {
	if ($Pause) {
		Write-Host ''
		Read-Host 'Enter キーで終了します'
	}
	exit $Code
}

if ($Unregister) {
	$exists = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
	if ($exists) {
		Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
		Write-Host ('タスクを削除しました: ' + $TaskPath + $TaskName)
	} else {
		Write-Host ('タスクが見つかりません: ' + $TaskPath + $TaskName)
	}
	Complete-Script 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmdPath = Join-Path $scriptDir $cmdName
if (-not (Test-Path -LiteralPath $cmdPath)) {
	Write-Host ('実行するコマンドが見つかりません: ' + $cmdPath) -ForegroundColor Red
	Complete-Script 1
}

$cmdReal = Resolve-SubstPath ([System.IO.Path]::GetFullPath($cmdPath))
$workDir = Split-Path -Parent $cmdReal
if ($cmdReal -ne $cmdPath) {
	Write-Host 'subst ドライブを実体パスへ直して登録します。'
}

# 実行ユーザーは、このスクリプトを動かしているユーザー。トーストはそのユーザーのデスクトップに出る
$user = $env:USERDOMAIN + '\' + $env:USERNAME
Write-Host ('実行ユーザー: ' + (Hide-Name $user))

if ($CheckArgs) {
	$action = New-ScheduledTaskAction -Execute $cmdReal -Argument $CheckArgs -WorkingDirectory $workDir
} else {
	$action = New-ScheduledTaskAction -Execute $cmdReal -WorkingDirectory $workDir
}
# :15 は最初の確認（異常でも通知しない）、:45 は再確認（なお異常なら通知）。判定は check-report 側が時刻で切り替える
if ($Target -eq 'collector') {
	# 10 分ごと（収集は 1 分ごとに書くため、止まってから最長 13 分ほどで気づく）
	$triggers = @(New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650))
	$whenText = '10 分ごと'
} else {
	$triggers = @('00:15', '00:45', '06:15', '06:45', '12:15', '12:45', '18:15', '18:45') | ForEach-Object { New-ScheduledTaskTrigger -Daily -At $_ }
	$whenText = '毎日 0:15・0:45・6:15・6:45・12:15・12:45・18:15・18:45'
}

# StartWhenAvailable … 実行時刻に電源が切れていたら、起動したときに実行する
# ExecutionTimeLimit … 判定は数秒で終わる。10 分で打ち切る
# MultipleInstances  … 前回がまだ動いていたら新しい方を捨てる
$settings = New-ScheduledTaskSettingsSet `
	-StartWhenAvailable `
	-ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
	-MultipleInstances IgnoreNew `
	-DontStopIfGoingOnBatteries `
	-AllowStartIfOnBatteries

# Interactive … ログオンしているときのみ実行する（トーストを出すため）
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

try {
	Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
		-Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
} catch {
	Write-Host ('登録に失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
	Complete-Script 1
}

Write-Host ''
Write-Host ('タスクを登録しました: ' + $TaskPath + $TaskName)
Write-Host ('  実行時刻: ' + $whenText)
Write-Host ('  実行内容: ' + (Split-Path -Leaf $cmdReal))
Write-Host ''
Write-Host '確認と変更はタスクスケジューラの GUI から行えます。'
Write-Host '削除するには -Unregister を付けて実行してください。'

Complete-Script 0
