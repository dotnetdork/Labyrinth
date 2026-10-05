#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
# Each item's state is its own id, so its fingerprint is fixed.
Write-LabItem -Id 'item-a' -Category 'sample' -Fingerprint (Get-LabItemFingerprint -Text 'item-a') -Reason 'first sample item'
Write-LabItem -Id 'item-b' -Category 'sample' -Fingerprint (Get-LabItemFingerprint -Text 'item-b') -Reason 'second sample item'
Write-LabItem -Id 'item-c' -Category 'other' -Fingerprint (Get-LabItemFingerprint -Text 'item-c') -Reason 'an item of another category'
exit 10
