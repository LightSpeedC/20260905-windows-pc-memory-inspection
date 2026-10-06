<#
.SYNOPSIS
	rust-ai-pc-memory-collector（メモリの時系列収集）をリリースビルドし、_bin/ に置く。

.DESCRIPTION
	src/pc-memory-collector を Rust（MSVC ツールチェーン）でビルドし、実行ファイルを _bin/rust-ai-pc-memory-collector.exe にコピーする。
	_bin/ は先頭 _ なので Git 管理外。サービスの導入（tools/70_deploy/install-collector-service.ps1）がここを使う。

.PARAMETER Pause
	終了時にキー入力を待つ。
#>
[CmdletBinding()]
param(
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
	$binDir = Join-Path $root '_bin'
	New-Item -ItemType Directory -Force -Path $binDir | Out-Null
	Copy-Item -LiteralPath $built -Destination (Join-Path $binDir 'rust-ai-pc-memory-collector.exe') -Force
	Write-Host ('置きました: _bin/rust-ai-pc-memory-collector.exe（{0:N1} MB）' -f ((Get-Item -LiteralPath $built).Length / 1MB))
	Complete-Script 0
} catch {
	Write-Host ('失敗しました: ' + $_.Exception.Message) -ForegroundColor Red
	Complete-Script 1
}
