#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'FAIL_VERIFY')) { Write-Output 'keeper: verify forced to fail'; exit 30 }
if (@(Get-Content -LiteralPath (Join-Path $env:LAB_ROOT 'keeper.conf')) -contains 'setting=on') { exit 0 }
exit 30
