#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
Add-LabManifestEntry -Action approved_items -Target $env:LAB_APPROVED
$approved = @()
foreach ($item in @('item-a', 'item-b', 'item-c')) {
    if ((Test-LabApproved -Id $item -Fingerprint (Get-LabItemFingerprint -Text $item)) -eq 0) { $approved += $item }
}
[IO.File]::WriteAllText((Join-Path $env:LAB_ROOT 'APPROVED_ITEMS'), (($approved | ForEach-Object { "$_`n" }) -join ''))
exit 0
