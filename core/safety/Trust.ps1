#Requires -Version 5.1
# core/safety/Trust.ps1: the ownership checks (design 21, section 5): can
# only Administrators, SYSTEM and TrustedInstaller change a folder, what it
# holds, and the folders above it? Dot-sourced through core/Lab.ps1.
#
# The installer also loads this file on its own, with the release check
# (core\safety\Release.ps1), so it can check its own release folder before
# it loads any other code from it. Like the release check, it needs nothing
# else from the core, and loading it changes nothing.

# Get-LabTrustedSid: the accounts that may own and use the data root:
# Administrators, SYSTEM and the account running Labyrinth.
function Get-LabTrustedSid {
    return @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
}

# Get-LabAdminSid: the accounts that may change Labyrinth's code and data:
# those of Get-LabTrustedSid, TrustedInstaller (which owns C:\ and much of
# Windows) and each account in the local Administrators group. The revert
# timer runs as SYSTEM, so it must also trust the administrator who ran
# the apply.
function Get-LabAdminSid {
    # NT SERVICE\TrustedInstaller, which owns C:\ and the system folders.
    $sids = @(Get-LabTrustedSid) + @('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    try {
        # The group's name depends on the language of Windows; its SID does not.
        $name = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/$name,group"
        foreach ($m in @($group.Invoke('Members'))) {
            $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
            $sids += (New-Object Security.Principal.SecurityIdentifier($bytes, 0)).Value
        }
    } catch {
        Write-Verbose "the Administrators group could not be listed: $($_.Exception.Message)"
    }
    return $sids | Select-Object -Unique
}

# Test-LabItemAcl -Path P -Trusted SIDS -Mask RIGHTS: is P owned by one of
# SIDS, with no other account allowed any of RIGHTS on P itself? Rules that
# only pass to what P holds are left to the items they reach.
function Test-LabItemAcl {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string[]] $Trusted, [Parameter(Mandatory)] [int] $Mask)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($Trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow') { continue }
        if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($Trusted -contains $r.IdentityReference.Value) { continue }
        if (([int]$r.FileSystemRights -band $Mask) -ne 0) { return $false }
    }
    return $true
}

# Find-LabUntrustedItem -Path P...: the first path that an account other
# than the trusted ones (Get-LabAdminSid) could change, or $null if there
# is none. SYSTEM runs the code, configuration and manifest under each P,
# the revert timer's rollback included, so an account that could write
# there could run its own code as SYSTEM (design 21, section 5). Each
# existing P, and everything in it, must be owned by a trusted account,
# with no other account allowed to write to it, delete it or change its
# access; each folder above P must not let another account delete, take or
# re-permission it or what it holds. Read only: nothing is re-permissioned.
function Find-LabUntrustedItem {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string[]] $Path)
    $trusted = @(Get-LabAdminSid)
    # Write data, append, write attributes and extended attributes, delete
    # a child, delete, change access, take ownership, generic all and write.
    $write = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    # Delete a child, delete, change access, take ownership, generic all.
    $replace = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000
    foreach ($p in $Path) {
        if ($p -eq '') { continue }
        $full = [IO.Path]::GetFullPath($p)
        if (Test-Path -LiteralPath $full) {
            $items = @(Get-Item -LiteralPath $full -Force) + @(Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop)
            foreach ($i in $items) {
                if (-not (Test-LabItemAcl -Path $i.FullName -Trusted $trusted -Mask $write)) { return $i.FullName }
            }
        }
        $d = Split-Path -Parent $full
        while ($d) {
            if ((Test-Path -LiteralPath $d) -and -not (Test-LabItemAcl -Path $d -Trusted $trusted -Mask $replace)) { return $d }
            $d = Split-Path -Parent $d
        }
    }
    return $null
}

