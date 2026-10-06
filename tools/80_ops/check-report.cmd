@echo off
rem 検知用タスクが指す起動役。実際の処理は node（TypeScript）の check-report.ts で行う。
rem 引数 now:<ISO 日時> を渡すと、その時刻として確認する（動作の確認用）。
rem 結果は logs\check-report.log に UTF-8 で残る。

where node >nul 2>&1
if errorlevel 1 (
	echo node が見つかりません。
	exit /b 1
)

node "%~dp0check-report.ts" %*
exit /b %errorlevel%
