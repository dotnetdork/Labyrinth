#Requires -Version 5.1
# core/config/Config.ps1: readers for the run-time configuration
# (docs/Conventions.md section 2.2). Dot-sourced through core/Lab.ps1.
#
# Configuration is data: every file is parsed line by line and never
# dot-sourced. Comments after '#' are removed, whitespace is trimmed and
# blank lines are skipped. A line that does not match its file's format
# throws an error naming the file and line number (the caller exits 40).
# A file that is missing, or holds no entries, gives $null (the caller
# decides whether that blocks the run, exit 20).

# Get-LabConfigLine PATH: the data lines of a file, as objects with No and
# Text. A file that cannot be read throws, so it is never taken for an empty one.
function Get-LabConfigLine {
    param([Parameter(Mandatory)] [string] $Path)
    $n = 0
    $all = $null
    try { $all = [IO.File]::ReadAllLines($Path) }
    catch [UnauthorizedAccessException] { throw "${Path}: cannot be read; it needs an elevated Administrator session" }
    foreach ($raw in $all) {
        $n++
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -ne '') { [pscustomobject]@{ No = $n; Text = $line } }
    }
}

# Read-LabEventConfig: event.conf (KEY=value) as a hashtable. The file is
# optional; the settings the core uses have defaults and are range-checked.
function Read-LabEventConfig {
    $settings = @{ REVERT_MINUTES = '5'; RING_MAX_HOSTS = '3'; PROBE_TIMEOUT = '5' }
    $file = Join-Path $env:LAB_CONFIG_DIR 'event.conf'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        foreach ($l in @(Get-LabConfigLine $file)) {
            if ($l.Text -cnotmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { throw "${file}:$($l.No): expected KEY=value" }
            $settings[$Matches[1]] = $Matches[2].Trim()
        }
    }
    foreach ($check in @(@('REVERT_MINUTES', 1, 60), @('RING_MAX_HOSTS', 1, 99), @('PROBE_TIMEOUT', 1, 60))) {
        $v = $settings[$check[0]]
        if ($v -notmatch '^[0-9]{1,3}$' -or [int]$v -lt $check[1] -or [int]$v -gt $check[2]) {
            throw "${file}: $($check[0]) must be a whole number from $($check[1]) to $($check[2])"
        }
        $settings[$check[0]] = [int]$v
    }
    return $settings
}

# Read-LabProtectedSet: protected-accounts as a hashtable (account -> class).
# The account is everything before the last word, so it may hold spaces.
# Account names compare case-insensitively, as Windows does.
function Read-LabProtectedSet {
    $classes = @('official', 'scoring', 'employee', 'operator', 'breakglass', 'service', 'builtin')
    $file = Join-Path $env:LAB_CONFIG_DIR 'protected-accounts'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $set = @{}
    foreach ($l in @(Get-LabConfigLine $file)) {
        if ($l.Text -cnotmatch '^(.*\S)\s+([a-z]+)$') { throw "${file}:$($l.No): expected: account class" }
        $name = $Matches[1]; $class = $Matches[2]
        if ($classes -cnotcontains $class) { throw "${file}:$($l.No): unknown class $class" }
        if ($set.ContainsKey($name) -and $set[$name] -cne $class) { throw "${file}:$($l.No): $name is listed with two classes" }
        $set[$name] = $class
    }
    if ($set.Count -eq 0) { return $null }
    return $set
}

# Test-LabAddress ADDRESS: is it an IPv4 or IPv6 address, with an optional
# CIDR prefix length?
function Test-LabAddress {
    param([string] $Address)
    $ip, $bits = $Address -split '/', 2
    if ($ip -match '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        foreach ($o in $Matches[1..4]) { if ([int]$o -gt 255) { return $false } }
        return ($null -eq $bits -or ($bits -match '^\d{1,2}$' -and [int]$bits -le 32))
    }
    # .NET parses the IPv6 form, so ':::' and the like are refused; the
    # character check keeps out a zone ID and other forms it also accepts.
    $parsed = $null
    if ($ip -match ':' -and $ip -match '^[0-9A-Fa-f:.]+$' -and [Net.IPAddress]::TryParse($ip, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ($null -eq $bits -or ($bits -match '^\d{1,3}$' -and [int]$bits -le 128))
    }
    return $false
}

# Read-LabAddressList NAME: an address list (scoring-allowlist, never-ban).
function Read-LabAddressList {
    param([Parameter(Mandatory)] [string] $Name)
    $file = Join-Path $env:LAB_CONFIG_DIR $Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $list = @()
    foreach ($l in @(Get-LabConfigLine $file)) {
        if (-not (Test-LabAddress $l.Text)) { throw "${file}:$($l.No): not an address or CIDR: $($l.Text)" }
        $list += $l.Text
    }
    if ($list.Count -eq 0) { return $null }
    return , $list
}

# Read-LabPreApproved: the pre-approval rules (pre-approved) as objects with
# Module, Category and Item, where Item is an item id or '*' for every item
# of the category (docs/Conventions.md section 3.1).
function Read-LabPreApproved {
    $file = Join-Path $env:LAB_CONFIG_DIR 'pre-approved'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $rules = @()
    foreach ($l in @(Get-LabConfigLine $file)) {
        if ($l.Text -cnotmatch '^((lockout|observe|deceive|sustain)\.[a-z0-9_-]+)\s+([a-z0-9-]+)\s+([a-z0-9-]+|\*)$') {
            throw "${file}:$($l.No): expected: module-id category item-id (or * for every item)"
        }
        $rules += [pscustomobject]@{ Module = $Matches[1]; Category = $Matches[3]; Item = $Matches[4] }
    }
    if ($rules.Count -eq 0) { return $null }
    return , $rules
}

# Read-LabServiceList: the scored-service list as objects with Name, Proto,
# Target, Port and Expect. Missing or empty: $null, because an empty list is
# one nobody filled in, and a module that touches scored services is blocked
# without one (docs/Conventions.md section 3.1).
function Read-LabServiceList {
    $protos = @('http', 'https', 'dns', 'smtp', 'pop3', 'ftp', 'tcp')
    $file = Join-Path $env:LAB_CONFIG_DIR 'services'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $list = @()
    foreach ($l in @(Get-LabConfigLine $file)) {
        $where = "${file}:$($l.No)"
        if ($l.Text -cnotmatch '^([A-Za-z0-9_.-]+)\s+([a-z0-9]+)\s+([A-Za-z0-9.:_-]+)\s+([0-9]{1,5})\s+(\S+)$') {
            throw "${where}: expected: name proto host port expect"
        }
        $svc = [pscustomobject]@{ Name = $Matches[1]; Proto = $Matches[2]; Target = $Matches[3]; Port = [int]$Matches[4]; Expect = $Matches[5] }
        # The probes pass these to commands, where a leading '-' reads as an
        # option; a lone '-' is the "no expected text" placeholder.
        if ($svc.Name.StartsWith('-') -or $svc.Target.StartsWith('-') -or ($svc.Expect.StartsWith('-') -and $svc.Expect -ne '-')) {
            throw "${where}: a value may not begin with '-'"
        }
        if ($protos -cnotcontains $svc.Proto) { throw "${where}: unknown protocol $($svc.Proto)" }
        if ($svc.Port -lt 1 -or $svc.Port -gt 65535) { throw "${where}: port out of range: $($svc.Port)" }
        if ($svc.Proto -eq 'dns' -and $svc.Expect -notmatch '^.+=.+$') { throw "${where}: a dns probe expects name=answer" }
        if (@($list | Where-Object { $_.Name -ceq $svc.Name }).Count -gt 0) { throw "${where}: duplicate service name $($svc.Name)" }
        $list += $svc
    }
    if ($list.Count -eq 0) { return $null }
    return , $list
}

# Find-LabHost NAME: this host's line in the hosts file, as an object with
# Group, Profile and Platform; $null if the file is missing or the host is
# not listed. Host names compare case-insensitively.
function Find-LabHost {
    param([Parameter(Mandatory)] [string] $Name)
    $platforms = @('ubuntu', 'rhel-family', 'windows', 'appliance')
    $file = Join-Path $env:LAB_CONFIG_DIR 'hosts'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $found = $null
    foreach ($l in @(Get-LabConfigLine $file)) {
        if ($l.Text -cnotmatch '^([A-Za-z0-9_.-]+)\s+(ring[0-9]+|manual)\s+([a-z0-9-]+)\s+([a-z-]+)$') {
            throw "${file}:$($l.No): expected: host group profile platform"
        }
        if ($platforms -cnotcontains $Matches[4]) { throw "${file}:$($l.No): unknown platform $($Matches[4])" }
        if ($Matches[1] -eq $Name) {
            $found = [pscustomobject]@{ Group = $Matches[2]; Profile = $Matches[3]; Platform = $Matches[4] }
        }
    }
    return $found
}
