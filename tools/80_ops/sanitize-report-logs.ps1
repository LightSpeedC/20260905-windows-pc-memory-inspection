# 生成済みレポート（HTML）に残った伏せ字の残骸を書き換える。
# 課題 i260908-01 を直す前のツールが出したレポートが対象。
#
# 伏せ字が単純な部分文字列の置換だったため、
#   1. 実体パスがドライブ表記へ戻らず、
#   2. そこにユーザー名の置換が掛かって、フォルダ名の残りが見えている
# 状態になっている。ここを実体パスの側から引き当てて直す。
#
# 伏せる対象の値はすべて環境変数から取る。スクリプトにリテラルで書かない。
#
# 既定は数えるだけ。書き換えるときは -Apply を付ける。

param(
	[string]$Path = '',
	[switch]$Apply
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($Path)) {
	$Path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'logs'
}
if (-not (Test-Path -LiteralPath $Path)) {
	Write-Host ('対象が見つからない: ' + $Path)
	exit 1
}

$user = $env:USERNAME
$host1 = $env:COMPUTERNAME
$root = $env:_SECRET_SUBST_N_DRIVE

if ([string]::IsNullOrEmpty($user)) {
	Write-Host 'ユーザー名が環境変数から取れない。中止する'
	exit 1
}

# subst の割り当てを実体パスから引き当てる
$drive = ''
if (-not [string]::IsNullOrEmpty($root)) {
	$rootTrim = $root.TrimEnd('\')
	foreach ($line in (subst)) {
		$m = [regex]::Match([string]$line, '^\s*([A-Za-z]:)\\:\s+=>\s+(.+?)\s*$')
		if ($m.Success -and $m.Groups[2].Value.TrimEnd('\') -eq $rootTrim) {
			$drive = $m.Groups[1].Value
			break
		}
	}
}

# 直す前の伏せ字が実体パスに対して作った形（HTML なので < > は実体参照）
$oldRootMasked = ''
if ($drive -and $root) {
	$oldRootMasked = ($root.TrimEnd('\') -replace [regex]::Escape($user), '&lt;username&gt;')
}

$mark = '2026-09-08 伏せ字の不備（i260908-01）を修正: 伏せ字が途中で切れていた箇所を書き換えた'

# 伏せ字の直後に続いてしまった文字。区切り・実体参照の始まり・空白は残す
$residueUser = '(&lt;username&gt;)[^\\/:"''\s&<]+'
$residueHost = '(&lt;hostname&gt;)[^\\/:"''\s&<]+'
$residueTilde = '(~)[^\\/:"''\s&<]+'

$files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*-log.html' | Sort-Object FullName)
if ($files.Count -eq 0) {
	Write-Host ('レポートが見つからない: ' + $Path)
	exit 1
}

Write-Host ($(if ($Apply) { '書き換える' } else { '数えるだけ（-Apply で書き換える）' }) + ' / 対象 ' + $files.Count + ' ファイル')
Write-Host ''
Write-Host 'ファイル                                  実体 残骸U 残骸H 残骸~ 印'

$totalRoot = 0
$totalUser = 0
$totalHost = 0
$totalTilde = 0
$changed = 0

foreach ($f in $files) {
	$text = [System.IO.File]::ReadAllText($f.FullName)
	$before = $text

	$nRoot = 0
	if ($oldRootMasked) {
		$nRoot = [regex]::Matches($text, [regex]::Escape($oldRootMasked)).Count
		$text = $text -replace [regex]::Escape($oldRootMasked), $drive
	}
	$nUser = [regex]::Matches($text, $residueUser).Count
	$text = $text -replace $residueUser, '$1'
	$nHost = [regex]::Matches($text, $residueHost).Count
	$text = $text -replace $residueHost, '$1'
	$nTilde = [regex]::Matches($text, $residueTilde).Count
	$text = $text -replace $residueTilde, '$1'

	# 書き換えた印を残す。二重には足さない
	$needMark = ($text -cne $before) -and ($text -notmatch [regex]::Escape($mark))
	if ($needMark) {
		$text = $text -replace '(?m)^</footer>$', ('<br>' + "`n" + $mark + "`n" + '</footer>')
	}

	$totalRoot += $nRoot
	$totalUser += $nUser
	$totalHost += $nHost
	$totalTilde += $nTilde

	Write-Host ('{0,-42}{1,5}{2,6}{3,6}{4,6}  {5}' -f $f.Name, $nRoot, $nUser, $nHost, $nTilde, $(if ($needMark) { '足す' } else { '—' }))

	if ($Apply -and ($text -cne $before)) {
		Set-Content -LiteralPath $f.FullName -Value $text -NoNewline -Encoding UTF8
		$changed++
	}
}

Write-Host ''
Write-Host ('合計: 実体 ' + $totalRoot + ' / 残骸U ' + $totalUser + ' / 残骸H ' + $totalHost + ' / 残骸~ ' + $totalTilde)
if ($Apply) {
	Write-Host ('書き換えたファイル: ' + $changed + ' 件')
	Write-Host 'このあと convert-encoding --to html で BOM と改行を揃えること'
} else {
	Write-Host '書き換えていない'
}
