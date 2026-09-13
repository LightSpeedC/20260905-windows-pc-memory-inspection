<#
.SYNOPSIS
	プロセスメモリ調査をタスクスケジューラへ登録する。

.DESCRIPTION
	inspect-process-memory.cmd を毎日決まった時刻に実行するタスクを作る。
	cmd には引数 nopause を渡すため、実行後にキー入力を待たない。

	実行ユーザーはシステム環境変数 _SECRET_CLAUDE_USERNAME から読む。

	【SYSTEM で実行してはいけない】
	cmd の中で claude を呼ぶが、claude の実行ファイルと認証情報はどちらも
	ユーザープロファイル配下にある。SYSTEM で動かすとプロファイルが
	C:\Windows\System32\config\systemprofile になり、コマンドが見つからず、
	見つかっても未認証で失敗する。必ず利用者のアカウントで実行する。

	【subst ドライブ】
	タスクスケジューラは別のログオンセッションで動くため N: が見えない。
	登録するパスは実体パスへ直す。cmd の中で subst を張り直すので、
	起動さえできればその後は N: で動く。

.PARAMETER TaskName
	タスク名。既定は「プロセスメモリ調査」。

.PARAMETER At
	実行時刻。既定は 03:00。

.PARAMETER LogonType
	Interactive … ログオン中のみ実行。パスワード不要（既定）
	Password    … ログオフ中も実行。登録時にパスワードの入力を求める
	S4U         … パスワード不要でログオフ中も実行。ネットワーク資格情報を持たない

.PARAMETER User
	実行ユーザー。省略時は _SECRET_CLAUDE_USERNAME を使う。

.PARAMETER Unregister
	登録を解除する。

.PARAMETER Pause
	終了時にキー入力を待つ。
#>
[CmdletBinding()]
param(
	[string]$TaskName = 'プロセスメモリ調査',
	[string]$At = '03:00',
	[ValidateSet('Interactive', 'Password', 'S4U')]
	[string]$LogonType = 'Interactive',
	[string]$User,
	[switch]$Unregister,
	[switch]$NoElevate,
	[switch]$Pause
)

$ErrorActionPreference = 'Stop'

# ==================================================================
# 小道具
# ==================================================================

# 表示にユーザー名やパスの実体を出さない
function Hide-Name([string]$Text) {
	if ([string]::IsNullOrEmpty($Text)) { return $Text }
	return '<' + $Text.Length + ' 文字>'
}

# システム環境変数を読む。
# 設定した直後は既存プロセスの環境に反映されないため、レジストリを直接見る
function Get-SystemEnv([string]$Name) {
	$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
	$p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
	if ($p -and ($p.PSObject.Properties.Name -contains $Name)) {
		return [string]$p.$Name
	}
	return ''
}

# subst で割り当てたドライブは別セッションから見えないため、実体パスへ直す
function Resolve-SubstPath([string]$Path) {
	$root = [System.IO.Path]::GetPathRoot($Path)
	if (-not $root) { return $Path }
	$drive = $root.TrimEnd('\')
	if ($drive.Length -ne 2) { return $Path }

	foreach ($line in (subst)) {
		# subst の出力は「N:\: => C:\〈実体フォルダ〉」の形
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if ($m.Success -and $m.Groups[1].Value -eq $drive) {
			return $m.Groups[2].Value + $Path.Substring($drive.Length)
		}
	}
	return $Path
}

function Test-Admin {
	return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Complete-Script([int]$Code) {
	if ($Pause) {
		Write-Host ''
		Read-Host 'Enter キーで終了します'
	}
	exit $Code
}

# ==================================================================
# 管理者権限へ昇格する
# ==================================================================

# 最上位の特権でタスクを登録するには管理者権限が要る。
# subst ドライブは昇格先から見えないため、自分のパスを実体へ直してから渡す
if ((-not (Test-Admin)) -and (-not $NoElevate)) {
	$selfReal = Resolve-SubstPath $MyInvocation.MyCommand.Path
	$q = [char]34
	$argLine = '-NoProfile -ExecutionPolicy Bypass -File ' + $q + $selfReal + $q + ' -NoElevate -Pause'
	if ($TaskName -ne 'プロセスメモリ調査') { $argLine += ' -TaskName ' + $q + $TaskName + $q }
	if ($At -ne '03:00')                   { $argLine += ' -At ' + $q + $At + $q }
	if ($LogonType -ne 'Interactive')      { $argLine += ' -LogonType ' + $LogonType }
	if ($User)                             { $argLine += ' -User ' + $q + $User + $q }
	if ($Unregister)                       { $argLine += ' -Unregister' }

	Write-Host '管理者権限で起動し直します...'
	try {
		Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $argLine -ErrorAction Stop
		exit 0
	} catch {
		Write-Host '  昇格が取り消されました。このまま非管理者で続行します。' -ForegroundColor Yellow
	}
}

# ==================================================================
# 登録の解除
# ==================================================================

if ($Unregister) {
	$exists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
	if ($exists) {
		Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
		Write-Host ('タスクを削除しました: ' + $TaskName)
	} else {
		Write-Host ('タスクが見つかりません: ' + $TaskName)
	}
	Complete-Script 0
}

# ==================================================================
# 実行ユーザーの決定
# ==================================================================

if (-not $User) { $User = $env:_SECRET_CLAUDE_USERNAME }
if (-not $User) { $User = Get-SystemEnv '_SECRET_CLAUDE_USERNAME' }

if (-not $User) {
	Write-Host '実行ユーザーが決まりません。' -ForegroundColor Red
	Write-Host 'システム環境変数 _SECRET_CLAUDE_USERNAME を設定するか、-User で指定してください。'
	Complete-Script 1
}

Write-Host ('実行ユーザー: ' + (Hide-Name $User))
Write-Host ('ログオン種別: ' + $LogonType)

# ==================================================================
# 登録するコマンドのパス
# ==================================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmdPath = Join-Path $scriptDir 'inspect-process-memory.cmd'

if (-not (Test-Path -LiteralPath $cmdPath)) {
	Write-Host ('実行するコマンドが見つかりません: ' + $cmdPath) -ForegroundColor Red
	Complete-Script 1
}

$cmdReal = Resolve-SubstPath ([System.IO.Path]::GetFullPath($cmdPath))
$workDir = Split-Path -Parent $cmdReal

if ($cmdReal -ne $cmdPath) {
	Write-Host 'subst ドライブを実体パスへ直して登録します。'
}

# ==================================================================
# 登録
# ==================================================================

if (-not (Test-Admin)) {
	Write-Host '※ 管理者権限で実行していません。最上位の特権での登録に失敗する場合があります。' -ForegroundColor Yellow
}

$action = New-ScheduledTaskAction -Execute $cmdReal -Argument 'nopause' -WorkingDirectory $workDir
$trigger = New-ScheduledTaskTrigger -Daily -At $At

# StartWhenAvailable  … 実行時刻を逃したら次に起動したときに実行する
# WakeToRun           … スリープから復帰させて実行する
# ExecutionTimeLimit  … claude の応答待ちが長引いても 1 時間で打ち切る
# MultipleInstances   … 前回がまだ動いていたら新しい方を捨てる
$settings = New-ScheduledTaskSettingsSet `
	-StartWhenAvailable `
	-WakeToRun `
	-ExecutionTimeLimit (New-TimeSpan -Hours 1) `
	-MultipleInstances IgnoreNew `
	-DontStopIfGoingOnBatteries `
	-AllowStartIfOnBatteries

try {
	if ($LogonType -eq 'Password') {
		# パスワードはスクリプトに書かず、その場で入力を受ける
		$cred = Get-Credential -UserName $User -Message 'タスクを実行するアカウントのパスワード'
		if (-not $cred) {
			Write-Host '入力が取り消されました。' -ForegroundColor Yellow
			Complete-Script 1
		}
		Register-ScheduledTask -TaskName $TaskName `
			-Action $action -Trigger $trigger -Settings $settings `
			-User $cred.UserName -Password $cred.GetNetworkCredential().Password `
			-RunLevel Highest -Force | Out-Null
	} else {
		$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType $LogonType -RunLevel Highest
		Register-ScheduledTask -TaskName $TaskName `
			-Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
	}
} catch {
	Write-Host ('登録に失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
	Complete-Script 1
}

Write-Host ''
Write-Host ('タスクを登録しました: ' + $TaskName)
Write-Host ('  実行時刻: 毎日 ' + $At)
Write-Host ('  実行内容: ' + (Split-Path -Leaf $cmdReal) + ' nopause')
Write-Host ''
Write-Host '確認と変更はタスクスケジューラの GUI から行えます。'
Write-Host '削除するには -Unregister を付けて実行してください。'

Complete-Script 0
