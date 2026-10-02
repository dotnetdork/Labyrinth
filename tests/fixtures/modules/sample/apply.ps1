#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -Path (Join-Path $env:LAB_ROOT "APPLIED") -Value applied
exit 0
