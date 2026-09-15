@echo off
rem タスクスケジューラはこのファイルを指す。
rem 実行内容を変えたいときは、この DEFAULT_ARGS の1行だけを直せばよい。
rem タスクの再登録は不要（Command が指す先はこのファイルのまま変わらないため）。
rem
rem 手動で個別に試すときは、この cmd を経由せず
rem tools\80_ops\inspect-process-memory.cmd を直接、好きな引数で呼ぶ。

set "DEFAULT_ARGS=nopause noai"
call "%~dp0tools\80_ops\inspect-process-memory.cmd" %DEFAULT_ARGS% %*
