@echo off
rem 収集サービスに、再起動を依頼する（管理者は要らない）。実際の処理は node（TypeScript）の request-restart.ts で行う。
rem 引数（任意）: base:<パス>  note:<理由>  timeout:<秒>
node "%~dp0request-restart.ts" %*
exit /b %errorlevel%
