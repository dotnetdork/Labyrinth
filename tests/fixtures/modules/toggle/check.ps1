#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$f = Join-Path $env:LAB_ROOT 'toggle.conf'
if ((Test-Path -LiteralPath $f) -and (@(Get-Content -LiteralPath $f) -contains 'setting=on')) { exit 0 }
Write-Output 'toggle: setting is not on'
exit 10
