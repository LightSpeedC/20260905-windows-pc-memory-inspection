# Rust（MSVC ツールチェーン）を使うための環境。dot-source して Use-RustMsvc を呼ぶと、cargo のパスを返す。
#
# この PC の PATH 上の rustc は GNU 構成のオフライン版で、C コンパイラが無く、SQLite 同梱（rusqlite）をビルドできない。
# rustup（C:/Tools/rust）の MSVC ツールチェーンを使う。置き場が違う環境では、環境変数 PC_MEMORY_RUST_ROOT で指す。

$script:RustRoot = if ($env:PC_MEMORY_RUST_ROOT) { $env:PC_MEMORY_RUST_ROOT } else { 'C:/Tools/rust' }

function Use-RustMsvc {
	$env:RUSTUP_HOME = $script:RustRoot + '/.rustup'
	$env:CARGO_HOME = $script:RustRoot + '/.cargo'
	$cargo = $script:RustRoot + '/.cargo/bin/cargo.exe'
	if (-not (Test-Path -LiteralPath $cargo)) {
		throw ('cargo が見つかりません: ' + $cargo)
	}
	return $cargo
}
