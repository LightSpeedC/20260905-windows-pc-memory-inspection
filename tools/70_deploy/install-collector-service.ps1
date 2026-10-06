<#
.SYNOPSIS
	rust-ai-pc-memory-collector を Windows サービス（winsw）として導入する。管理者権限が要る。

.DESCRIPTION
	_bin/ に、実行ファイル・winsw・winsw の定義（XML）をそろえ、サービスを導入して起動する。
	すでに導入済みなら、止めて入れ直す（定義や実行ファイルの更新を反映するため）。
	事前に tools/20_build/build-collector.ps1 で _bin/rust-ai-pc-memory-collector.exe を作っておく。

	【winsw の実行ファイル】
	Git に入れない。ai-chat-lite の winsw を複製して使う（既定: T:/ai-chat-lite/node-ai-chat-lite-winsw.exe）。

	【subst ドライブ】
	サービスは別のログオンセッションで動くため W: が見えない。導入は実体のフォルダで行う。

.PARAMETER Uninstall
	サービスを止めて、削除する。

.PARAMETER WinswSource
	複製元の winsw の実行ファイル。

.PARAMETER Pause
	終了時にキー入力を待つ。
#>
[CmdletBinding()]
param(
	[switch]$Uninstall,
	[string]$WinswSource = 'T:/ai-chat-lite/node-ai-chat-lite-winsw.exe',
	[switch]$NoElevate,
	[switch]$Pause
)

$ErrorActionPreference = 'Stop'
$ServiceId = 'rust-ai-pc-memory-collector'

function Complete-Script([int]$Code) {
	if ($Pause) {
		Write-Host ''
		Read-Host 'Enter キーで終了します'
	}
	exit $Code
}

function Test-Admin {
	return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# subst で割り当てたドライブは昇格先・サービスから見えないため、実体パスへ直す
function Resolve-SubstPath([string]$Path) {
	$rootPath = [System.IO.Path]::GetPathRoot($Path)
	if (-not $rootPath) { return $Path }
	$drive = $rootPath.TrimEnd('\')
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

# 管理者へ昇格（自分のパスは実体へ直してから渡す）
if ((-not (Test-Admin)) -and (-not $NoElevate)) {
	$selfReal = Resolve-SubstPath $MyInvocation.MyCommand.Path
	$q = [char]34
	$argLine = '-NoProfile -ExecutionPolicy Bypass -File ' + $q + $selfReal + $q + ' -NoElevate -Pause'
	if ($Uninstall) { $argLine += ' -Uninstall' }
	if ($WinswSource -ne 'T:/ai-chat-lite/node-ai-chat-lite-winsw.exe') { $argLine += ' -WinswSource ' + $q + $WinswSource + $q }
	Write-Host '管理者権限で起動し直します...'
	try {
		Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $argLine -ErrorAction Stop
		exit 0
	} catch {
		Write-Host '  昇格が取り消されました。このまま非管理者で続行します（失敗する場合があります）。' -ForegroundColor Yellow
	}
}

try {
	$root = Resolve-SubstPath (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
	$binDir = Join-Path $root '_bin'
	$winsw = Join-Path $binDir 'rust-ai-pc-memory-collector-winsw.exe'

	function Invoke-Winsw([string]$Command) {
		& $winsw $Command
		return $LASTEXITCODE
	}

	$exists = [bool](Get-Service -Name $ServiceId -ErrorAction SilentlyContinue)

	# 導入済みなら、止めて削除する（入れ直しの前提。-Uninstall のときはこれで終わり）
	if ($exists) {
		if (-not (Test-Path -LiteralPath $winsw)) {
			Write-Host ('サービスは導入済みですが、winsw が見つかりません: ' + $winsw) -ForegroundColor Red
			Complete-Script 1
		}
		Write-Host 'サービスを止めます...'
		[void](Invoke-Winsw 'stop')
		Write-Host 'サービスを削除します...'
		if ((Invoke-Winsw 'uninstall') -ne 0) {
			Write-Host '削除に失敗しました。' -ForegroundColor Red
			Complete-Script 1
		}
	}
	if ($Uninstall) {
		Write-Host ('サービスを削除しました: ' + $ServiceId)
		Complete-Script 0
	}

	# 必要なものを _bin/ にそろえる
	$exe = Join-Path $binDir 'rust-ai-pc-memory-collector.exe'
	if (-not (Test-Path -LiteralPath $exe)) {
		Write-Host ('実行ファイルがありません: ' + $exe) -ForegroundColor Red
		Write-Host '先に tools/20_build/build-collector.cmd を実行してください。'
		Complete-Script 1
	}
	if (-not (Test-Path -LiteralPath $winsw)) {
		if (-not (Test-Path -LiteralPath $WinswSource)) {
			Write-Host ('winsw の複製元が見つかりません: ' + $WinswSource) -ForegroundColor Red
			Complete-Script 1
		}
		Copy-Item -LiteralPath $WinswSource -Destination $winsw
		Write-Host 'winsw を複製しました。'
	}
	Copy-Item -LiteralPath (Join-Path $root 'tools/80_ops/winsw/rust-ai-pc-memory-collector-winsw.xml') -Destination (Join-Path $binDir 'rust-ai-pc-memory-collector-winsw.xml') -Force

	Write-Host 'サービスを導入します...'
	if ((Invoke-Winsw 'install') -ne 0) {
		Write-Host '導入に失敗しました。' -ForegroundColor Red
		Complete-Script 1
	}
	Write-Host 'サービスを起動します...'
	if ((Invoke-Winsw 'start') -ne 0) {
		Write-Host '起動に失敗しました。' -ForegroundColor Red
		Complete-Script 1
	}

	Start-Sleep -Seconds 5
	$svc = Get-Service -Name $ServiceId -ErrorAction SilentlyContinue
	Write-Host ''
	Write-Host ('サービス: ' + $ServiceId + ' / 状態: ' + $svc.Status + ' / 開始の種類: ' + $svc.StartType)
	Write-Host 'DB: _data/pc-memory.db / バックアップ: _backup/ / ログ: _bin/logs/'
	Complete-Script 0
} catch {
	Write-Host ('失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
	Complete-Script 1
}
