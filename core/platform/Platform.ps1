#Requires -Version 5.1
# core/platform/Platform.ps1: the platform facts for Windows (design 19,
# section 3). Dot-sourced through core/Lab.ps1. Reading a fact changes
# nothing.
#
# Get-LabFact -Name NAME returns one fact, worked out on first use and kept
# for the rest of the process; Get-LabFact with no name returns every fact,
# in order. Clear-LabFact forgets them, so the next read works them out again.

$script:LabFactNames = @('os_caption', 'os_build', 'role', 'firewall', 'secure_boot', 'ad_module', 'splunk_forwarder')
$script:LabFactCache = @{}

# Test-LabTool -Name TOOL: is TOOL a command on this host?
function Test-LabTool {
    param([Parameter(Mandatory)] [string] $Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Clear-LabFact {
    $script:LabFactCache = @{}
}

function Get-LabFact {
    param([string] $Name)
    if (-not $Name) {
        $all = [ordered]@{}
        foreach ($n in $script:LabFactNames) { $all[$n] = Get-LabFact -Name $n }
        return $all
    }
    if ($script:LabFactNames -notcontains $Name) { throw "Get-LabFact: unknown fact $Name" }
    if (-not $script:LabFactCache.ContainsKey($Name)) {
        $script:LabFactCache[$Name] = Get-LabFactValue -Name $Name
    }
    return $script:LabFactCache[$Name]
}

function Get-LabFactValue {
    param([Parameter(Mandatory)] [string] $Name)
    switch ($Name) {
        'os_caption' { return Get-LabOsField -Field 'Caption' }
        'os_build' { return Get-LabOsField -Field 'BuildNumber' }
        'role' { return Get-LabHostRole }
        'firewall' { return Get-LabFirewallState }
        'secure_boot' { return Get-LabSecureBootState }
        'ad_module' {
            if (Get-Module -ListAvailable -Name ActiveDirectory) { return 'yes' }
            return 'no'
        }
        'splunk_forwarder' {
            if (Get-Service -Name SplunkForwarder -ErrorAction SilentlyContinue) { return 'yes' }
            return 'no'
        }
    }
}

function Get-LabOsField {
    param([Parameter(Mandatory)] [string] $Field)
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        return 'unknown'
    }
    $value = [string]$os.$Field
    if (-not $value) { return 'unknown' }
    return $value
}

# ProductType: 1 workstation, 2 domain controller, 3 server.
function Get-LabHostRole {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    } catch {
        return 'unknown'
    }
    switch ([int]$os.ProductType) {
        1 { return 'workstation' }
        2 { return 'domain-controller' }
        3 {
            if ($cs.PartOfDomain) { return 'member-server' }
            return 'standalone-server'
        }
    }
    return 'unknown'
}

# on: every profile on; off: none on; partial: some on.
function Get-LabFirewallState {
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    } catch {
        return 'unknown'
    }
    if ($profiles.Count -eq 0) { return 'unknown' }
    $on = @($profiles | Where-Object { "$($_.Enabled)" -eq 'True' }).Count
    if ($on -eq $profiles.Count) { return 'on' }
    if ($on -eq 0) { return 'off' }
    return 'partial'
}

# Confirm-SecureBootUEFI throws PlatformNotSupportedException on a host
# without UEFI, and another error without administrator rights.
function Get-LabSecureBootState {
    if (-not (Test-LabTool -Name 'Confirm-SecureBootUEFI')) { return 'unknown' }
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { return 'on' }
        return 'off'
    } catch [System.PlatformNotSupportedException] {
        return 'unsupported'
    } catch {
        return 'unknown'
    }
}
