#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$f = Join-Path $env:LAB_ROOT 'keeper.conf'
if ((Test-Path -LiteralPath $f) -and (@(Get-Content -LiteralPath $f) -contains 'setting=on')) { exit 0 }
Write-Output 'keeper: setting is not on'
exit 10
