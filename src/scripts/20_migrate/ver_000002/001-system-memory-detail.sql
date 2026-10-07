-- system_memory に、コミットの内訳を調べる列を足す（i261007-01。コミットが急に増えたとき、プロセスの合計と合わない分の行き先を探す）。
-- サイズは byte。過去の行は、取っていなかったので NULL のまま（0 で埋めない）。
-- 版 1 の swap_used は、OS が返す commit_used − phys_total の計算値で、実際のページファイルの使用量ではない。
-- 実際の使用量は、新しい pagefile_used を見る。
--
-- 当て済みの環境では二度と実行されない。書き換えてはいけない（指紋が食い違い、起動が止まる）。

-- 実際のページファイルの使用量。ページファイルが無い、または読めなかったとき NULL
ALTER TABLE system_memory ADD COLUMN pagefile_used INTEGER;
-- 起動してからの、ページファイル使用量のピーク。読めなかったとき NULL
ALTER TABLE system_memory ADD COLUMN pagefile_peak INTEGER;
-- カーネルのページング可能プール。OS が返さない（Windows 以外）とき NULL
ALTER TABLE system_memory ADD COLUMN kernel_paged INTEGER;
-- カーネルのページング不可プール（ドライバーが物理メモリに固定する分）。OS が返さないとき NULL
ALTER TABLE system_memory ADD COLUMN kernel_nonpaged INTEGER;
-- システムキャッシュ。OS が返さないとき NULL
ALTER TABLE system_memory ADD COLUMN system_cache INTEGER;
