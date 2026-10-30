@echo off
rem laby.cmd: the installed command "laby" on Windows (install.ps1 puts this
rem folder on the machine PATH). It runs labyrinth.ps1 beside it with
rem Windows PowerShell and passes the exit code back. -ExecutionPolicy Bypass
rem applies to this one process only; the host's execution policy is never
rem changed. LAB_SELF makes the runner print its name as "laby"; setlocal
rem keeps it from leaking into the caller's session.
setlocal
set "LAB_SELF=laby"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0labyrinth.ps1" %*
exit /b %ERRORLEVEL%
