#Requires -Version 5.1
# core/approval/Approval.ps1: items for approval modules (docs/Conventions.md
# section 3.1, "Approval items"). Dot-sourced through core/Lab.ps1.
#
# An approval module's plan prints one line per item it would change, with
# Write-LabItem. Its apply changes an item only when Test-LabApproved says a
# person approved it and it has not changed since the plan.

# Get-LabItemFingerprint -Text STATE: the fingerprint of an item's state: the
# first 12 hex digits of the SHA-256 of STATE as UTF-8.
function Get-LabItemFingerprint {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    } finally {
        $sha.Dispose()
    }
    return ((@($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12))
}

# Write-LabItem -Id -Category -Fingerprint -Reason: one item line for the
# plan, on standard output. Tabs and other control characters in the reason
# become spaces. A malformed field throws.
function Write-LabItem {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Fingerprint,
        [AllowEmptyString()] [string] $Reason = ''
    )
    if ($Id -cnotmatch '^[a-z0-9-]+$' -or $Category -cnotmatch '^[a-z0-9-]+$' -or $Fingerprint -cnotmatch '^[0-9a-f]{12}$') {
        throw "approval: malformed item: id $Id, category $Category, fingerprint $Fingerprint"
    }
    $Reason = $Reason -replace '[\x00-\x1f\x7f]', ' '
    Write-Output ("item`t{0}`t{1}`t{2}`t{3}" -f $Id, $Category, $Fingerprint, $Reason)
}

# Test-LabApproved -Id -Fingerprint: may apply change item Id, whose state
# has Fingerprint now? Returns 0 when a person approved it and it is
# unchanged since the plan, and 1 when it was not approved. Returns 2 when it
# was approved but has changed since: it is recorded as refused and must be
# left alone.
function Test-LabApproved {
    param([Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [string] $Fingerprint)
    foreach ($entry in @("$env:LAB_APPROVED" -split '\s+' | Where-Object { $_ -ne '' })) {
        $at = $entry.LastIndexOf('@')
        if ($at -lt 0 -or $entry.Substring(0, $at) -cne $Id) { continue }
        $approved = $entry.Substring($at + 1)
        if ($approved -ceq $Fingerprint) { return 0 }
        try {
            Add-LabManifestEntry -Action approval_refused -Target $Id -Prev $approved -Note "changed since the plan; now $Fingerprint"
        } catch {
            [Console]::Error.WriteLine("approval: $($_.Exception.Message)")
        }
        Write-LabLog -Level warn -EventName approval_refused -Message "$Id changed since the plan, so it was left alone"
        return 2
    }
    return 1
}
