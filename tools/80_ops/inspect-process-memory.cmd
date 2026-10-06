@echo off
rem タスクスケジューラが指す起動役。実際の処理は node（TypeScript）の inspect-process-memory.ts で行う。
rem 引数（nopause・noai・model:<名前>・effort:<値>）はそのまま渡す。
rem 実行の経過は logs\task-run.log に UTF-8 で残る。ここでは node が見つからないときだけ終了コード 1 を返す。

where node >nul 2>&1
if errorlevel 1 (
	echo node が見つかりません。
	exit /b 1
)

node "%~dp0inspect-process-memory.ts" %*
exit /b %errorlevel%
