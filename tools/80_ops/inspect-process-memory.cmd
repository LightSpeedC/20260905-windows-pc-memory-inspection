@echo off
rem 全プロセスのメモリ調査を行い、logs へ HTML レポートを出力したあと、
rem claude に考察を書き足させる。
rem
rem 引数（順番は問わない）
rem     nopause   実行後にキー入力を待たない。昇格もブラウザ表示もしない
rem     noai      claude による考察の追記を行わない
rem
rem subst で割り当てた N ドライブは別のログオンセッションからは見えないため、
rem 接続先をシステム環境変数 _SECRET_SUBST_N_DRIVE から読んで張り直す。

setlocal

rem 引数のどこにあっても拾う
set "NOPAUSE="
set "NOAI="
for %%a in (%*) do (
	if /i "%%~a" == "nopause" set "NOPAUSE=1"
	if /i "%%~a" == "noai" set "NOAI=1"
)

if not defined _SECRET_SUBST_N_DRIVE (
	echo 環境変数 _SECRET_SUBST_N_DRIVE が設定されていません。
	goto :end
)

rem 既に張られているときは何もしない。
rem 二重に subst すると Drive already SUBSTed が出るため、存在を見てから張る
if not exist N:\ subst N: "%_SECRET_SUBST_N_DRIVE%"

cd /d "N:\2026\20260905-windows-pc-memory-inspection"
if errorlevel 1 (
	echo N ドライブへ移動できませんでした。
	goto :end
)

rem タスクスケジューラからは昇格の確認ダイアログを出せないので自己昇格を止める。
rem 管理者で動かしたい場合はタスク側で「最上位の特権で実行する」を有効にする
set "PSARGS=-Open"
if defined NOPAUSE set "PSARGS=-NoElevate"

powershell -NoProfile -ExecutionPolicy Bypass -File "tools/80_ops/inspect-process-memory.ps1" %PSARGS%

if defined NOAI goto :end

rem ps1 が書き残した直近の出力を読む。
rem 自分で探すと for /f の中でパイプの扱いを誤りやすいので、ファイル経由にする
set "REPORT="
if exist "logs\last-report.txt" for /f "usebackq delims=" %%f in ("logs\last-report.txt") do set "REPORT=%%f"

rem REPORT が空でも偽になるので、defined ではなく exist で見る
if not exist "%REPORT%" (
	echo レポートが見つかりませんでした。
	goto :end
)

echo 考察を追記します: %REPORT%
claude -p "%REPORT% に考察を追加して"

:end
if not defined NOPAUSE pause
