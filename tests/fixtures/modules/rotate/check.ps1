#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$f = Join-Path $env:LAB_ROOT 'rotate.pw'
if ((Test-Path -LiteralPath $f) -and ([IO.File]::ReadAllText($f).Trim() -match '^[0-9a-f]{64}$')) { exit 0 }
Write-Output 'rotate: testuser has its old password'
exit 10
