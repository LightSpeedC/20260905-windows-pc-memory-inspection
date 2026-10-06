# tests 配下のテストを全件実行する。個別に実行しないと通らないテストを残さないため、
# ここから一括で回せる状態を保つ。

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$testDir = Join-Path $root 'tests'

if (-not (Test-Path -LiteralPath $testDir)) {
	Write-Host ('テストの置き場が見つからない: ' + $testDir)
	exit 1
}

$files = @(Get-ChildItem -LiteralPath $testDir -Filter 'test-*.ps1' -File | Sort-Object Name)
if ($files.Count -eq 0) {
	Write-Host ('テストが見つからない: ' + $testDir)
	exit 1
}

Write-Host ('テスト ' + $files.Count + ' 本を実行する')

$ng = 0
$ngFiles = @()
foreach ($f in $files) {
	# 対象を渡し損ねると既定の探索範囲に落ちるため、渡す値が空でないことを確かめる
	$full = $f.FullName
	if ([string]::IsNullOrEmpty($full)) {
		Write-Host '対象のパスが空。中止する'
		exit 1
	}
	Write-Host ''
	Write-Host ('=== ' + $f.Name + ' ===')
	& $full
	if ($LASTEXITCODE -ne 0) {
		$ng += $LASTEXITCODE
		$ngFiles += $f.Name
	}
}

# node:test のテスト（*.test.ts）。対象は絶対パスで渡す（$testDir は上で存在を確かめ済み）。
# bun がある環境では bun test でも通ることを確かめる
$nodeTests = @(Get-ChildItem -LiteralPath $testDir -Filter '*.test.ts' -File)
if ($nodeTests.Count -gt 0) {
	Write-Host ''
	Write-Host ('=== node --test（' + $nodeTests.Count + ' ファイル）===')
	node --test $testDir
	if ($LASTEXITCODE -ne 0) {
		$ng += 1
		$ngFiles += 'node --test'
	}
	if (Get-Command bun -ErrorAction SilentlyContinue) {
		Write-Host ''
		Write-Host '=== bun test ==='
		bun test $testDir
		if ($LASTEXITCODE -ne 0) {
			$ng += 1
			$ngFiles += 'bun test'
		}
	}
}

# Rust（src/pc-memory-collector）のテスト。MSVC ツールチェーンは tools/20_build/rust-env.ps1 で指す
$collectorDir = Join-Path $root 'src/pc-memory-collector'
if (Test-Path -LiteralPath (Join-Path $collectorDir 'Cargo.toml')) {
	. (Join-Path $root 'tools/20_build/rust-env.ps1')
	Write-Host ''
	Write-Host '=== cargo test（src/pc-memory-collector）==='
	Push-Location $collectorDir
	try {
		& (Use-RustMsvc) test --no-fail-fast
		if ($LASTEXITCODE -ne 0) {
			$ng += 1
			$ngFiles += 'cargo test'
		}
	} finally {
		Pop-Location
	}
}

Write-Host ''
if ($ng -eq 0) {
	Write-Host ('全件成功（' + $files.Count + ' 本）')
} else {
	Write-Host ('失敗 ' + $ng + ' 件: ' + ($ngFiles -join ', '))
}
exit $ng
