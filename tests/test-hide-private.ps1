# Hide-Private（伏せ字）の回帰テスト。
# 実際のユーザー名やフォルダ名は使わず、合成した値を差し込んで判定する。
# 対象は inspect-process-memory.ps1 の本体から切り出すため、
# スクリプトを直したらこのテストがそのまま新しい実装を見る。

$ErrorActionPreference = 'Stop'

$target = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/80_ops/inspect-process-memory.ps1'
if (-not (Test-Path -LiteralPath $target)) {
	Write-Host ('対象が見つからない: ' + $target)
	exit 1
}

# 伏せ字の定義だけを切り出す。目印は「$script:UserProfile の代入」から
# 「function Format-MB」の直前まで。目印が動いたら止める
$lines = [System.IO.File]::ReadAllLines($target)
$from = -1
$to = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
	if ($from -lt 0 -and $lines[$i] -match '^\$script:UserProfile') { $from = $i }
	if ($lines[$i] -match '^function Format-MB') { $to = $i - 1; break }
}
if ($from -lt 0 -or $to -le $from) {
	Write-Host '切り出しの目印が見つからない。テストの側を直す'
	exit 1
}
$src = ($lines[$from..$to] -join "`r`n")
foreach ($needed in 'function Hide-Private', 'function Find-SubstRoot') {
	if ($src -notmatch [regex]::Escape($needed)) {
		Write-Host ('切り出しに ' + $needed + ' が含まれていない。テストの側を直す')
		exit 1
	}
}

# 昇格の引数は渡っていない状態（タスクスケジューラ・管理者コンソールの経路）
$SubstRoot = ''
$SubstDrive = ''
Invoke-Expression $src

# 合成した値に差し替える。実在の名前を使わない
$script:UserProfile = 'C:\Users\user1'
$script:UsersRoot = 'C:\Users'
$script:UserName = 'user1'
$script:ComputerName = 'HOST1'
$script:FoundSubstRoot = 'C:\user1work'
$script:FoundSubstDrive = 'N:'

$ng = 0
function Test-Case([string]$Name, [string]$Text, [string]$Expected) {
	$actual = Hide-Private $Text
	if ($actual -ceq $Expected) {
		Write-Host ('  OK   ' + $Name)
	} else {
		Write-Host ('  NG   ' + $Name)
		Write-Host ('       期待 ' + $Expected)
		Write-Host ('       実際 ' + $actual)
		$script:ng++
	}
}

Write-Host 'Hide-Private の伏せ字'

Test-Case 'subst の実体パスはドライブ表記に戻る（引数が渡らない経路）' `
	'C:\user1work\2026\proj\tools\80_ops\x.cmd' `
	'N:\2026\proj\tools\80_ops\x.cmd'

Test-Case '引用符の中の実体パスもドライブ表記に戻る' `
	'C:\WINDOWS\system32\cmd.exe /c ""C:\user1work\2026\proj\x.cmd" "' `
	'C:\WINDOWS\system32\cmd.exe /c ""N:\2026\proj\x.cmd" "'

Test-Case 'ユーザープロファイル配下は ~ になる' `
	'C:\Users\user1\AppData\Local\Temp\a.txt' `
	'~\AppData\Local\Temp\a.txt'

Test-Case 'プロファイル名で始まる別フォルダは要素ごと伏せる（残骸を出さない）' `
	'C:\Users\user1ki\Documents\b.txt' `
	'C:\Users\<username>\Documents\b.txt'

Test-Case 'ユーザー名で始まる別フォルダも要素ごと伏せる' `
	'C:\user1extra\c.txt' `
	'C:\<username>\c.txt'

Test-Case 'コマンドラインの裸のユーザー名を伏せる' `
	'"C:\Program Files\App\app.exe" --user user1 --out D:\user1-work\d.log' `
	'"C:\Program Files\App\app.exe" --user <username> --out D:\<username>\d.log'

Test-Case 'コンピューター名も要素ごと伏せる' `
	'\\HOST1\share\e.txt' `
	'\\<hostname>\share\e.txt'

Test-Case 'ユーザー名を含まないパスは変わらない' `
	'C:\WINDOWS\system32\svchost.exe -k netsvcs -p' `
	'C:\WINDOWS\system32\svchost.exe -k netsvcs -p'

Test-Case 'SID はマシン固有の数字を伏せる（SearchProtocolHost.exe のパイプ名で見つかった形）' `
	'"C:\WINDOWS\System32\SearchProtocolHost.exe" Global\UsGthrFltPipeMssGthrPipe_S-1-5-21-1111111111-2222222222-3333333333-10014_' `
	'"C:\WINDOWS\System32\SearchProtocolHost.exe" Global\UsGthrFltPipeMssGthrPipe_<sid>_'

Test-Case '空文字はそのまま返る' '' ''

# 伏せ字の直後に文字が続いていないことを横断で見る。
# 「ユーザー名が 0 件」だけを数えると、置換後に残った断片を見落とす
Write-Host '伏せ字の直後に文字が続かない'
$inputs = @(
	'C:\Users\user1ki\Documents\b.txt',
	'C:\user1extra\c.txt',
	'C:\user1work\2026\proj\x.cmd',
	'\\HOST1extra\share\e.txt',
	'--user user1ki --host HOST1ki'
)
foreach ($one in $inputs) {
	$actual = Hide-Private $one
	$residue = [regex]::Matches($actual, '<(?:username|hostname)>(?![\\/:"'' ]|$)').Count
	$leakUser = [regex]::Matches($actual, [regex]::Escape($script:UserName)).Count
	$leakHost = [regex]::Matches($actual, [regex]::Escape($script:ComputerName)).Count
	if ($residue -eq 0 -and $leakUser -eq 0 -and $leakHost -eq 0) {
		Write-Host ('  OK   ' + $actual)
	} else {
		Write-Host ('  NG   ' + $actual + '（残骸 ' + $residue + ' / 名前 ' + ($leakUser + $leakHost) + '）')
		$ng++
	}
}

# subst の引き当ては実環境を見る。割り当てが無い環境ではスキップする
Write-Host 'Find-SubstRoot の引き当て'
$realRoot = $env:_SECRET_SUBST_N_DRIVE
if ([string]::IsNullOrEmpty($realRoot)) {
	Write-Host '  スキップ  subst の割り当てが環境変数に無い'
} else {
	$script:FoundSubstRoot = ''
	$script:FoundSubstDrive = ''
	Find-SubstRoot (Join-Path $realRoot '2026')
	if ($script:FoundSubstDrive -and $script:FoundSubstRoot) {
		Write-Host ('  OK   実体パスから ' + $script:FoundSubstDrive + ' を引き当てた')
	} else {
		Write-Host '  NG   実体パスから割り当てを引き当てられなかった'
		$ng++
	}
	$script:FoundSubstRoot = ''
	$script:FoundSubstDrive = ''
	Find-SubstRoot 'C:\WINDOWS\system32'
	if ($script:FoundSubstDrive) {
		Write-Host '  NG   関係の無いパスで引き当ててしまった'
		$ng++
	} else {
		Write-Host '  OK   関係の無いパスでは引き当てない'
	}
}

if ($ng -eq 0) {
	Write-Host '結果: すべて通った'
} else {
	Write-Host ('結果: ' + $ng + ' 件 失敗')
}
exit $ng
