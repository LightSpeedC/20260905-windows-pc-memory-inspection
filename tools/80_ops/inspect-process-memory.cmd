@echo off
rem 全プロセスのメモリ調査を行い、logs へ HTML レポートを出力したあと、
rem claude に考察を書き足させる。
rem
rem 引数（順番は問わない）
rem     nopause      実行後にキー入力を待たない。昇格もブラウザ表示もしない
rem     noai         claude による考察の追記を行わない
rem     model:<名前>  考察に使うモデルを指定する（省略時はアカウントの既定）
rem     effort:<値>   考察の思考の深さを指定する（省略時は既定）
rem     ※ = ではなく : で区切る。cmd は = をスペースと同じ引数区切りとして扱うため、
rem       model=sonnet と書くと model と sonnet に割れてしまう（引用符が無い限り）
rem
rem subst で割り当てた N ドライブは別のログオンセッションからは見えないため、
rem 接続先をシステム環境変数 _SECRET_SUBST_N_DRIVE から読んで張り直す。

setlocal enabledelayedexpansion

rem 引数のどこにあっても拾う
set "NOPAUSE="
set "NOAI="
set "MODEL="
set "EFFORT="
for %%a in (%*) do (
	set "ARG=%%~a"
	if /i "%%~a" == "nopause" set "NOPAUSE=1"
	if /i "%%~a" == "noai" set "NOAI=1"
	if /i "!ARG:~0,6!" == "model:" set "MODEL=!ARG:~6!"
	if /i "!ARG:~0,7!" == "effort:" set "EFFORT=!ARG:~7!"
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

rem claude へ渡すモデル・effort のフラグを組み立てる。指定が無ければ既定のまま呼ぶ
set "CLAUDEFLAGS="
if defined MODEL set "CLAUDEFLAGS=%CLAUDEFLAGS% --model %MODEL%"
if defined EFFORT set "CLAUDEFLAGS=%CLAUDEFLAGS% --effort %EFFORT%"

echo 考察を追記します: %REPORT%
if defined MODEL (echo モデル: %MODEL%（指定）) else (echo モデル: 既定)
if defined EFFORT (echo effort: %EFFORT%（指定）) else (echo effort: 既定)
echo ---- 観点ファイルの内容 ----
node -p "fs.readFileSync('inspect-process-memory-observations.md').toString()"
echo -----------------------------
echo この処理は数分（実測で5分程度）かかることがあります。画面に何も出なくても止まっていません。そのままお待ちください。
claude%CLAUDEFLAGS% -p "%REPORT% に、inspect-process-memory-observations.md の内容を踏まえて考察（ch06）を追加して"

:end
if not defined NOPAUSE pause
