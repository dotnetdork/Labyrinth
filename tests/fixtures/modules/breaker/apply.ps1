#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
$f = Join-Path $env:LAB_ROOT 'probe-state'
Backup-LabFile -Path $f
[IO.File]::WriteAllText($f, "web.test fail`n")
exit 0
