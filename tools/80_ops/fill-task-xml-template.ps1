<#
.SYNOPSIS
	タスク登録 XML の雛形（tools/80_ops/ai-pc-inspect-process-memory.xml）を
	実値で埋める。

.DESCRIPTION
	雛形に残したプレースホルダを、このマシンの実値で置き換えて tmp/ に書き出す。
	埋めた結果が etc/ のコピー（実値のまま保存してある登録済みタスクの控え）と
	一致するかを確かめるための、検証専用のスクリプト。

	【実際の登録はしない】
	このスクリプトは schtasks を呼ばない。埋めた結果を tmp/ に書き出すところまで。
	登録をやり直す必要が生じたときは、そのとき指示を受けてから実装する
	（notes/10_plan/p260908-01-タスク登録XMLの雛形化.html 参照）。

	【埋める値の出どころ】
	{USER_SID}        … whoami /user の出力から取る
	{PROJECT_ROOT}     … subst の割り当てを実体パスの側から引き当てる
	{USER_ACCOUNT}     … $env:USERDOMAIN + '\' + $env:USERNAME
	{TASK_FOLDER_NAME} … 対応する環境変数が無いため -TaskFolderName で指定する
	                     （実装時に見つかった 5 個目のプレースホルダ。
	                     タスクスケジューラのフォルダ名に実在の個人名が入っていたため追加した）

.PARAMETER TemplatePath
	雛形 XML のパス。既定は自分と同じフォルダの ai-pc-inspect-process-memory.xml。

.PARAMETER OutPath
	埋めた結果の書き出し先。既定は tmp/ai-pc-inspect-process-memory-filled.xml。

.PARAMETER TaskFolderName
	{TASK_FOLDER_NAME} に入れる値。省略すると埋めずに止まる。
#>
[CmdletBinding()]
param(
	[string]$TemplatePath,
	[string]$OutPath,
	[string]$TaskFolderName
)

$ErrorActionPreference = 'Stop'

# ==================================================================
# 小道具
# ==================================================================

# subst で割り当てたドライブは、実体パスの側から引き当てる
# （tools/80_ops/inspect-process-memory.ps1 の Find-SubstRoot と同じ考え方）
function Find-ProjectRoot([string]$ScriptDir) {
	# tools/80_ops の 2 つ上がプロジェクトルート
	$projectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

	foreach ($line in (subst)) {
		# 「W:\: => C:\〈実体フォルダ〉」の形
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if (-not $m.Success) { continue }
		$drive = $m.Groups[1].Value
		if ($projectRoot.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase)) {
			# W:\2026\... の W: を実体パスへ差し替える
			return $m.Groups[2].Value.TrimEnd('\') + $projectRoot.Substring($drive.Length)
		}
	}
	# subst 経由でなければそのまま返す
	return $projectRoot
}

function Get-CurrentUserSid {
	$out = & whoami /user /fo csv /nh
	if (-not $out) { throw 'whoami /user から SID を取得できませんでした。' }
	$fields = $out | ConvertFrom-Csv -Header 'Account', 'Sid'
	return $fields.Sid
}

# ==================================================================
# 埋める値をそろえる
# ==================================================================

if (-not $TemplatePath) {
	$TemplatePath = Join-Path $PSScriptRoot 'ai-pc-inspect-process-memory.xml'
}
if (-not (Test-Path -LiteralPath $TemplatePath)) {
	Write-Host ('雛形が見つかりません: ' + $TemplatePath) -ForegroundColor Red
	exit 1
}

if (-not $TaskFolderName) {
	Write-Host '{TASK_FOLDER_NAME} に入れる値が要ります。-TaskFolderName で指定してください。' -ForegroundColor Red
	Write-Host '（対応する環境変数が無いため、他の 3 個と違い引数での指定が必須です）'
	exit 1
}

$values = @{
	'{USER_SID}'         = Get-CurrentUserSid
	'{PROJECT_ROOT}'     = Find-ProjectRoot $PSScriptRoot
	'{USER_ACCOUNT}'     = $env:USERDOMAIN + '\' + $env:USERNAME
	'{TASK_FOLDER_NAME}' = $TaskFolderName
}

Write-Host '埋める値がそろいました（実値は表示しません）:'
foreach ($key in $values.Keys) {
	Write-Host ('  ' + $key + ' … <' + $values[$key].Length + ' 文字>')
}

# ==================================================================
# 置き換え
# ==================================================================

$content = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
foreach ($key in $values.Keys) {
	$content = $content.Replace($key, $values[$key])
}

# 埋め残しが無いことを確かめる
if ($content -match '\{[A-Z_]+\}') {
	Write-Host ('埋め残しのプレースホルダがあります: ' + $Matches[0]) -ForegroundColor Red
	exit 1
}

# ==================================================================
# 書き出し
# ==================================================================

if (-not $OutPath) {
	$tmpDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tmp'
	if (-not (Test-Path -LiteralPath $tmpDir)) {
		New-Item -ItemType Directory -Path $tmpDir | Out-Null
	}
	$OutPath = Join-Path $tmpDir 'ai-pc-inspect-process-memory-filled.xml'
}

# BOM 無し UTF-8 で書く（雛形と同じ文字コード。実際の登録に使う場合は
# convert-encoding --to reg で UTF-16LE + BOM + CRLF に変換してから渡す）
[System.IO.File]::WriteAllText($OutPath, $content, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('埋めた結果を書き出しました: ' + $OutPath)
Write-Host '※ このスクリプトは検証専用です。schtasks への登録は行っていません。'
