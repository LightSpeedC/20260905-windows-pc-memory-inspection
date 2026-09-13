@echo off
rem プロセスメモリ調査をタスクスケジューラへ登録する。
rem
rem 管理者権限への昇格は ps1 側で行う。subst で割り当てたドライブは昇格先から
rem 見えないため、ps1 が自分のパスを実体へ直してから昇格する。
rem
rem 登録を解除するときは第 1 引数に unregister を渡す。
rem     register-inspect-task.cmd unregister

if "%~1" == "unregister" (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-inspect-task.ps1" -Unregister
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-inspect-task.ps1"
)
pause
