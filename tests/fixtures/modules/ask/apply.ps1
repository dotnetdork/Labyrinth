#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
Add-LabManifestEntry -Action approved_items -Target $env:LAB_APPROVED
[IO.File]::WriteAllText((Join-Path $env:LAB_ROOT 'APPROVED_ITEMS'), "$env:LAB_APPROVED`n")
exit 0
