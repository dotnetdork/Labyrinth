#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
Restore-LabBackup
exit 0
