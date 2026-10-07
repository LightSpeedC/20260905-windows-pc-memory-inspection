@echo off
rem 収集サービスに、いまのプロセスの状態の調査を依頼する（管理者は要らない）。実際の処理は node（TypeScript）の request-inspect.ts で行う。
rem 引数（任意）: top:<件数>  sort:commit|working_set  note:<理由>  timeout:<秒>  base:<パス>
node "%~dp0request-inspect.ts" %*
exit /b %errorlevel%
