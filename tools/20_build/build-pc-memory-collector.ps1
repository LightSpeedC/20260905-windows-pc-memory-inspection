<#
.SYNOPSIS
	rust-ai-pc-memory-collector（メモリの時系列収集）をリリースビルドし、deploy/ に置く。

.DESCRIPTION
	src/pc-memory-collector を Rust（MSVC ツールチェーン）でビルドし、実行ファイルを deploy/rust-ai-pc-memory-collector.exe にコピーする。
	deploy/ の exe は Git 管理外（.gitignore）。サービスの導入（tools/70_deploy/install-pc-memory-collector-service.ps1）がここを使う。

.PARAMETER Restart
	置き替えのあとに、動いているサービスへ、再起動を依頼する（管理者は要らない）。
	受信箱（_data/request/inbox）に依頼を置き、サービスが新しい exe で起動し直すまで待つ（tools/80_ops/request-restart.ts）。

.PARAMETER Pause
	終了時にキー入力を待つ。
#>
[CmdletBinding()]
param(
	[switch]$Restart,
	[switch]$Pause
)

$ErrorActionPreference = 'Stop'

function Complete-Script([int]$Code) {
	if ($Pause) {
		Write-Host ''
		Read-Host 'Enter キーで終了します'
	}
	exit $Code
}

# 新しい exe を置く。サービスが動いている間は、置き先の exe が掴まれていて、上書きも削除もできない。
# Windows は、実行中の exe の名前を変える（退避する）ことはできるので、退避してから新しい exe を置く。
# 動いている旧い exe は、そのまま動き続ける。新しい exe に切り替わるのは、サービスの再起動のとき。
# 前回までに退避して、もう掴まれていないものは、ここで消す（退避先に溜めない）
function Set-ExeFile([string]$Built, [string]$Dest, [string]$OldDir) {
	New-Item -ItemType Directory -Force -Path $OldDir | Out-Null
	Get-ChildItem -LiteralPath $OldDir -Filter 'rust-ai-pc-memory-collector-old-*.exe' -File | ForEach-Object {
		try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
	}
	if (Test-Path -LiteralPath $Dest) {
		$old = Join-Path $OldDir ('rust-ai-pc-memory-collector-old-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.exe')
		Move-Item -LiteralPath $Dest -Destination $old
	}
	Copy-Item -LiteralPath $Built -Destination $Dest
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'rust-env.ps1')

try {
	$cargo = Use-RustMsvc
	Push-Location (Join-Path $root 'src/pc-memory-collector')
	try {
		Write-Host 'リリースビルドします...'
		& $cargo build --release
		if ($LASTEXITCODE -ne 0) {
			Write-Host 'ビルドに失敗しました。' -ForegroundColor Red
			Complete-Script 1
		}
	} finally {
		Pop-Location
	}

	$built = Join-Path $root 'src/pc-memory-collector/target/release/rust-ai-pc-memory-collector.exe'
	$binDir = Join-Path $root 'deploy'
	New-Item -ItemType Directory -Force -Path $binDir | Out-Null
	Set-ExeFile $built (Join-Path $binDir 'rust-ai-pc-memory-collector.exe') (Join-Path $root 'tmp')
	Write-Host ('置きました: deploy/rust-ai-pc-memory-collector.exe（{0:N1} MB）' -f ((Get-Item -LiteralPath $built).Length / 1MB))
	if ($Restart) {
		# サービスの再起動を、受信箱の依頼で行う。結果（完了・失敗・時間切れ）が出るまで待つ
		Write-Host 'サービスに、再起動を依頼します...'
		node (Join-Path $root 'tools/80_ops/request-restart.ts') 'note:build-pc-memory-collector -Restart'
		Complete-Script $LASTEXITCODE
	}
	Write-Host '動いているサービスは、旧い exe のままです。新しい exe に切り替えるには、-Restart を付けて実行し直すか、サービスを再起動します。'
	Complete-Script 0
} catch {
	Write-Host ('失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
	Complete-Script 1
}
