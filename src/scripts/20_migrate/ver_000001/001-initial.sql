-- 初期のテーブル。日時はすべて JST の yyyy/mm/dd hh:mm:ss.ccc（固定 23 文字の TEXT。ai-chat-lite に合わせた形で、
-- 辞書順がそのまま時系列順になる）。サイズは byte。
-- OS に無い値・権限が無くて読めなかった値は NULL にする（0 や空文字で埋めない）。
-- 列名は、主キーが <テーブル>_id、外部キーは参照先の主キーと同じ名前、日時は _at、真偽値は is_。
--
-- 当て済みの環境では二度と実行されない。書き換えてはいけない（指紋が食い違い、起動が止まる）。

-- 1 分ごとのシステム全体のメモリ。1 分ごとの行が、そのまま収集の生存確認になる
CREATE TABLE system_memory (
	measured_at  TEXT    PRIMARY KEY
	               CHECK (length(measured_at) = 23),
	phys_total   INTEGER NOT NULL,
	phys_avail   INTEGER NOT NULL,
	swap_total   INTEGER,          -- Windows ではページファイルの合計
	swap_used    INTEGER,
	commit_limit INTEGER,
	commit_used  INTEGER
) STRICT;

-- 1 時間ごとのプロセスのスナップショット
CREATE TABLE process_snapshot (
	process_snapshot_id           INTEGER PRIMARY KEY,
	measured_at                   TEXT    NOT NULL
	                                CHECK (length(measured_at) = 23),
	logical_cpu_count             INTEGER NOT NULL,
	process_count                 INTEGER NOT NULL,
	command_line_unreadable_count INTEGER NOT NULL,   -- コマンドラインが取れなかった数（黙って欠けないため）
	-- 管理者権限（昇格済み、または LocalSystem）で動いていたか。UAC で昇格していない管理者アカウントは 0。
	-- 権限で、読めなかったプロセスの数が大きく変わるため、あとから区別できるように残す
	is_admin                      INTEGER NOT NULL
	                                CHECK (is_admin IN (0, 1))
) STRICT;
CREATE INDEX process_snapshot_ix_measured_at ON process_snapshot (measured_at);

-- コマンドラインは毎時間ほぼ同じなので、重複を持たず id で参照する
CREATE TABLE command_line (
	command_line_id   INTEGER PRIMARY KEY,
	command_line_body TEXT    NOT NULL UNIQUE
) STRICT;

CREATE TABLE process_sample (
	process_snapshot_id INTEGER NOT NULL REFERENCES process_snapshot (process_snapshot_id),
	pid                 INTEGER NOT NULL,
	started_at          TEXT    NOT NULL    -- 起動時刻。pid は再利用されるため、必ず組み合わせて同じプロセスを見分ける
	                      CHECK (length(started_at) = 23),
	parent_pid          INTEGER,
	process_name        TEXT    NOT NULL,
	exe_path            TEXT,
	command_line_id     INTEGER REFERENCES command_line (command_line_id),
	-- 次の 3 列は、権限が無くて読めなかったプロセスでは NULL（OS の中核が該当する。0 で書くと「暇だった」「使っていない」と読めてしまう）
	cpu_total_ms        INTEGER,            -- CPU 時間の累計（ミリ秒）
	cpu_percent         REAL,               -- 前回のスナップショットとの差から出した、全体に対する割合。前回が無い・前回か今回が読めなければ NULL
	memory_bytes        INTEGER,            -- 物理メモリ（Windows では WS）
	virtual_bytes       INTEGER,
	PRIMARY KEY (process_snapshot_id, pid, started_at)
) STRICT, WITHOUT ROWID;
CREATE INDEX process_sample_ix_pid_started_at ON process_sample (pid, started_at);

-- 開始・停止・エラー・バックアップの記録
CREATE TABLE collector_event (
	collector_event_id INTEGER PRIMARY KEY,
	occurred_at        TEXT    NOT NULL
	                     CHECK (length(occurred_at) = 23),
	event_kind         TEXT    NOT NULL,
	event_message      TEXT    NOT NULL
) STRICT;
CREATE INDEX collector_event_ix_occurred_at ON collector_event (occurred_at);
