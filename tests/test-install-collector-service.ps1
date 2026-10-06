# install-collector-service.ps1 の回帰テスト。
# 管理者へ昇格すると、ユーザーの subst（W: ・ T: 等）は見えなくなる。そのため、昇格する前に、
# 渡すパスをすべて実体のパスへ直しておく必要がある。
# 実際に起きた不具合: winsw の複製元の既定値（T:/ai-chat-lite/…）を直していなかった。
# さらに、区切りが / のパスは、ドライブの判定（TrimEnd('\')）で外れ、直されないまま素通りしていた。

$ErrorActionPreference = 'Stop'

$target = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/70_deploy/install-collector-service.ps1'
if (-not (Test-Path -LiteralPath $target)) {
	Write-Host ('対象が見つからない: ' + $target)
	exit 1
}

# 関数の定義だけを切り出す（スクリプトを実行すると、導入が走ってしまうため）
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Resolve-SubstPath' }, $true)
if (-not $fn) {
	Write-Host '切り出す関数 Resolve-SubstPath が見つからない。テストの側を直す'
	exit 1
}
Invoke-Expression $fn.Extent.Text

$ng = 0
function Test-Equal([string]$Name, [string]$Actual, [string]$Expected) {
	if ($Actual -ceq $Expected) {
		Write-Host ('  OK   ' + $Name)
	} else {
		Write-Host ('  NG   ' + $Name)
		Write-Host ('       期待 ' + $Expected)
		Write-Host ('       実際 ' + $Actual)
		$script:ng++
	}
}

# 使われていないドライブ文字に、一時のフォルダを subst で割り当てて試す。終わったら必ず外す
$used = [System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }
$letter = 'Y', 'X', 'V', 'U', 'S' | Where-Object { $used -notcontains $_ } | Select-Object -First 1
if (-not $letter) {
	Write-Host '  スキップ  空いているドライブ文字が無い'
} else {
	$real = Join-Path (Split-Path -Parent $PSScriptRoot) ('tmp/test-subst-' + [guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $real | Out-Null
	$real = (Resolve-Path -LiteralPath $real).Path
	$drive = $letter + ':'
	subst $drive $real
	try {
		Write-Host 'Resolve-SubstPath'
		Test-Equal '区切りが \ のパスは、実体のパスに直る' (Resolve-SubstPath ($drive + '\a\b.exe')) ($real + '\a\b.exe')
		Test-Equal '区切りが / のパスも、実体のパスに直る（以前は素通りしていた）' (Resolve-SubstPath ($drive + '/a/b.exe')) ($real + '\a\b.exe')
		Test-Equal 'ドライブ直下も直る' (Resolve-SubstPath ($drive + '/')) ($real + '\')
		Test-Equal 'subst ではないドライブのパスは、そのまま' (Resolve-SubstPath 'C:\Windows\System32') 'C:\Windows\System32'
	} finally {
		subst $drive /D
		Remove-Item -LiteralPath $real -Recurse -Force
	}
}

# 昇格の引数に、実体へ直した複製元を、必ず渡す（既定値のときも）
Write-Host '昇格の引数'
$text = [System.IO.File]::ReadAllText($target)
if ($text -match "WinswSource\s+-ne") {
	Write-Host '  NG   複製元を、既定値のときは渡さない作りになっている（昇格先で T: が見えず、見つからない）'
	$ng++
} else {
	Write-Host '  OK   複製元は、既定値でも渡す'
}
if ($text -match 'Resolve-SubstPath\s+\$WinswSource') {
	Write-Host '  OK   昇格の前に、複製元を実体のパスへ直している'
} else {
	Write-Host '  NG   昇格の前に、複製元を実体のパスへ直していない'
	$ng++
}

# サービスの置き場は deploy/（共通ルールの「デプロイ定義」）。ai-chat-lite の課題 i260830-01 と同じ向き。
# 定義の XML は deploy/ に置いて Git に入れる。exe（ビルドした本体・winsw の複製）は deploy/ に置くが、Git に入れない
Write-Host 'サービスの置き場（deploy/）'
$root = Split-Path -Parent $PSScriptRoot
$xmlPath = Join-Path $root 'deploy/rust-ai-pc-memory-collector-winsw.xml'
if (Test-Path -LiteralPath $xmlPath) {
	$xml = [System.IO.File]::ReadAllText($xmlPath)
	if ($xml -match '<id>rust-ai-pc-memory-collector</id>' -and $xml -match '<executable>rust-ai-pc-memory-collector\.exe</executable>') {
		Write-Host '  OK   定義の XML が deploy/ にあり、サービス ID と実行ファイル名が合っている'
	} else {
		Write-Host '  NG   deploy/ の XML のサービス ID か実行ファイル名が違う'
		$ng++
	}
} else {
	Write-Host '  NG   定義の XML が deploy/ に無い'
	$ng++
}
foreach ($name in 'tools/70_deploy/install-collector-service.ps1', 'tools/20_build/build-collector.ps1') {
	$src = [System.IO.File]::ReadAllText((Join-Path $root $name))
	if ($src -match '_bin|80_ops/winsw') {
		Write-Host ('  NG   ' + $name + ' が、旧い置き場（_bin・tools/80_ops/winsw）を指している')
		$ng++
	} else {
		Write-Host ('  OK   ' + $name + ' は、旧い置き場を指していない')
	}
}
$ignore = [System.IO.File]::ReadAllText((Join-Path $root '.gitignore'))
if ($ignore -match '(?m)^deploy/\*\.exe\s*$') {
	Write-Host '  OK   .gitignore が deploy/ の exe を除外している'
} else {
	Write-Host '  NG   .gitignore が deploy/ の exe を除外していない（winsw の複製とビルドした本体が Git に入ってしまう）'
	$ng++
}

if ($ng -eq 0) {
	Write-Host '結果: すべて通った'
} else {
	Write-Host ('結果: ' + $ng + ' 件 失敗')
}
exit $ng
