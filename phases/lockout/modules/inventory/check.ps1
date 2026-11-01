#Requires -Version 5.1
# lockout.inventory, check: record what the host has and what each scored
# service connects out to (design 08, section 3.1). Read-only: with
# LAB_DRY_RUN=1 (a preview, or the plan stage of a run) it prints what it
# found and writes nothing; with LAB_DRY_RUN=0 (the runner's recording call,
# design 00, section 4) it also writes the inventory and the dependency map
# under the state folder. It only observes, so it exits 0.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
. (Join-Path $env:LAB_ROOT 'phases\lockout\modules\inventory\Inventory.ps1')

try {
    $data = Get-InvCollectedAll
    $script:InvMapAll = @()
    $services = Get-InvServiceList
    if ($null -ne $services) {
        $script:InvMapAll = @(Get-InvMapLine $services $data.Socket $data.Process)
    }
    Write-InvFound
    if ($env:LAB_DRY_RUN -eq '0') {
        try { Write-InvState } catch {
            Write-Output "problem: the inventory could not be written under $(Join-Path $env:LAB_STATE_DIR 'inventory')"
            exit 40
        }
    }
} catch {
    Write-Output "problem: the inventory failed: $($_.Exception.Message)"
    exit 40
}
exit 0
