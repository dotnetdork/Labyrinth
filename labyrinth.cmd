@echo off
rem labyrinth.cmd: the installed command "labyrinth" on Windows (install.ps1 puts this
rem folder on the machine PATH). It runs labyrinth.ps1 beside it with
rem Windows PowerShell and passes the exit code back. -ExecutionPolicy Bypass
rem applies to this one process only; the host's execution policy is never
rem changed. LAB_SELF makes the runner print its name as "labyrinth"; setlocal
rem keeps it from leaking into the caller's session.
setlocal
set "LAB_SELF=labyrinth"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0labyrinth.ps1" %*
exit /b %ERRORLEVEL%
