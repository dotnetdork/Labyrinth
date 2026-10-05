#Requires -Version 5.1
# platform\windows\Firewall.ps1: the Windows Firewall adapter (design 19,
# section 5). A module dot-sources it after core\Lab.ps1:
#
#   . (Join-Path $env:LAB_ROOT 'platform\windows\Firewall.ps1')
#
# It keeps the same rules as the Linux adapter: no change without a snapshot
# taken by the same module in the same run, every change recorded in the
# manifest before it is made, and no default deny until every address in the
# scoring allowlist has an allow.
#
# Each function returns 0 done, 20 refused, 30 restore did not give back the
# saved state, or 40 error, so a module can pass the code on as its exit
# code. The reason goes to standard error.

$script:LabFirewallGroup = 'Labyrinth'

function Write-LabFirewallError {
    param([Parameter(Mandatory)] [string] $Message)
    [Console]::Error.WriteLine("firewall: $Message")
}

# Invoke-LabNetsh ARGS: run netsh, throwing on a non-zero exit code.
function Invoke-LabNetsh {
    param([Parameter(Mandatory)] [string[]] $Argument)
    $out = & netsh.exe @Argument 2>&1
    if ($LASTEXITCODE -ne 0) { throw "netsh $($Argument -join ' ') failed: $out" }
}

function Get-LabFirewallAllowFile {
    return Join-Path (Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $env:LAB_RUN_ID) 'firewall-allows'
}

# Test-LabFirewallChange -Action NAME: 0 if a change may go ahead, else 20.
function Test-LabFirewallChange {
    param([Parameter(Mandatory)] [string] $Action)
    if ($env:LAB_DRY_RUN -ne '0') {
        Write-LabFirewallError "$Action is refused in plan mode"
        return 20
    }
    $state = Get-LabFact -Name firewall
    if ($state -eq 'unknown') {
        Write-LabFirewallError "the Windows Firewall state is unknown (design 19, section 3); nothing was changed"
        return 20
    }
    return 0
}

# Get-LabFirewallSnapshotList: the snapshot folders the current module
# recorded in the current run, newest first.
function Get-LabFirewallSnapshotList {
    $entries = @(Get-LabManifestEntry | Where-Object { $_.module -ceq $env:LAB_MODULE_ID -and $_.action -ceq 'firewall_snapshot' })
    [array]::Reverse($entries)
    return @($entries | ForEach-Object { $_.backup })
}

function Test-LabFirewallSnapshotTaken {
    param([Parameter(Mandatory)] [string] $Action)
    if (@(Get-LabFirewallSnapshotList).Count -eq 0) {
        Write-LabFirewallError "$Action is refused: this module has taken no firewall snapshot in this run"
        return $false
    }
    return $true
}

# Get-LabFirewallRuleState: the profiles and rules as text, one line each,
# sorted, so two snapshots can be compared.
function Get-LabFirewallRuleState {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop | Sort-Object Name)) {
        $lines.Add(('profile {0} enabled={1} in={2} out={3} allowrules={4}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction, $p.DefaultOutboundAction, $p.AllowInboundRules))
    }
    $ports = @{}
    foreach ($f in @(Get-NetFirewallPortFilter -All -ErrorAction Stop)) { $ports[$f.InstanceID] = '{0} {1}' -f $f.Protocol, ($f.LocalPort -join ',') }
    $addrs = @{}
    foreach ($f in @(Get-NetFirewallAddressFilter -All -ErrorAction Stop)) { $addrs[$f.InstanceID] = ($f.RemoteAddress -join ',') }
    foreach ($r in @(Get-NetFirewallRule -ErrorAction Stop | Sort-Object Name)) {
        $lines.Add(('rule {0} enabled={1} {2} {3} profile={4} ports={5} from={6}' -f $r.Name, $r.Enabled, $r.Direction, $r.Action, $r.Profile, $ports[$r.Name], $addrs[$r.Name]))
    }
    return ($lines -join "`n")
}

function Save-LabFirewallSnapshot {
    param([string] $Path)
    $rc = Test-LabFirewallChange -Action 'snapshot'
    if ($rc -ne 0) { return $rc }
    try {
        if (-not $Path) {
            $Path = Join-Path (Join-Path (Join-Path $env:LAB_BACKUP_DIR $env:LAB_RUN_ID) $env:LAB_MODULE_ID) ('{0}-firewall' -f (Get-LabManifestNextSeq))
        }
        if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
            Write-LabFirewallError "snapshot folder is not empty: $Path"
            return 40
        }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Invoke-LabNetsh -Argument @('advfirewall', 'export', (Join-Path $Path 'firewall.wfw'))
        [IO.File]::WriteAllText((Join-Path $Path 'state'), (Get-LabFirewallRuleState))
        [IO.File]::WriteAllText((Join-Path $Path 'backend'), 'windows')
        Add-LabManifestEntry -Action firewall_snapshot -Target 'windows' -Backup $Path
        Write-LabLog -EventName firewall_snapshot -Message "saved the Windows Firewall rules to $Path"
    } catch {
        Write-LabFirewallError "the snapshot failed: $($_.Exception.Message)"
        return 40
    }
    return 0
}

function Restore-LabFirewallSnapshot {
    param([Parameter(Mandatory)] [string] $Path)
    $stateFile = Join-Path $Path 'state'
    $wfw = Join-Path $Path 'firewall.wfw'
    if (-not (Test-Path -LiteralPath $stateFile) -or -not (Test-Path -LiteralPath $wfw)) {
        Write-LabFirewallError "not a firewall snapshot: $Path"
        return 40
    }
    try {
        Invoke-LabNetsh -Argument @('advfirewall', 'import', $wfw)
        $now = Get-LabFirewallRuleState
    } catch {
        Write-LabFirewallError "the restore failed from ${Path}: $($_.Exception.Message)"
        return 40
    }
    if ($now -cne [IO.File]::ReadAllText($stateFile)) {
        Write-LabFirewallError "the Windows Firewall rules differ from the snapshot in $Path after the restore"
        return 30
    }
    return 0
}

function Add-LabFirewallAllow {
    param(
        [Parameter(Mandatory)] [string] $Protocol,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $Source
    )
    if ($Protocol -cne 'tcp' -and $Protocol -cne 'udp') { Write-LabFirewallError "protocol must be tcp or udp: $Protocol"; return 40 }
    if ($Port -lt 1 -or $Port -gt 65535) { Write-LabFirewallError "not a port: $Port"; return 40 }
    if ($Source -cne 'any' -and -not (Test-LabAddress $Source)) { Write-LabFirewallError "not an address or CIDR: $Source"; return 40 }
    $rc = Test-LabFirewallChange -Action 'allow'
    if ($rc -ne 0) { return $rc }
    if (-not (Test-LabFirewallSnapshotTaken -Action 'allow')) { return 20 }
    $file = Get-LabFirewallAllowFile
    $entry = "$Protocol $Port $Source"
    if ((Test-Path -LiteralPath $file) -and ([IO.File]::ReadAllLines($file) -ccontains $entry)) { return 0 }
    try {
        Add-LabManifestEntry -Action firewall_allow -Target "$Protocol/$Port from $Source" -Note 'windows'
        $remote = 'Any'
        if ($Source -cne 'any') { $remote = $Source }
        New-NetFirewallRule -DisplayName "Labyrinth: allow $Protocol/$Port from $Source" -Group $script:LabFirewallGroup `
            -Direction Inbound -Action Allow -Protocol $Protocol.ToUpperInvariant() -LocalPort $Port -RemoteAddress $remote `
            -Profile Any -ErrorAction Stop | Out-Null
        Add-LabTextLine -Path $file -Line $entry
        Write-LabLog -EventName firewall_allow -Message "allowed $Protocol/$Port from $Source (windows)"
    } catch {
        Write-LabFirewallError "the allow for $Protocol/$Port from $Source failed: $($_.Exception.Message)"
        return 40
    }
    return 0
}

# Test-LabFirewallScoringCovered: 0 when every scoring-allowlist address has
# been the source of an allow in this run, else 20 (or 40 if the list does
# not load).
function Test-LabFirewallScoringCovered {
    try {
        $list = Read-LabAddressList 'scoring-allowlist'
    } catch {
        Write-LabFirewallError 'default deny is refused: the scoring allowlist does not load'
        return 40
    }
    if (-not $list) {
        Write-LabFirewallError 'default deny is refused: the scoring allowlist is missing or empty'
        return 20
    }
    $seen = @{}
    $file = Get-LabFirewallAllowFile
    if (Test-Path -LiteralPath $file) {
        foreach ($l in [IO.File]::ReadAllLines($file)) {
            $parts = $l -split ' '
            if ($parts.Count -eq 3) { $seen[$parts[2]] = $true }
        }
    }
    $missing = @($list | Where-Object { -not $seen.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Write-LabFirewallError "default deny is refused: no allow yet from the scoring address(es) $($missing -join ' ')"
        return 20
    }
    return 0
}

# Windows Firewall keeps established connections and loopback itself. ICMP is
# allowed in both families (design 01, section 2), then every profile is
# turned on with inbound default Block and local allow rules honored.
function Enable-LabFirewallDefaultDeny {
    $rc = Test-LabFirewallChange -Action 'default_deny_in'
    if ($rc -ne 0) { return $rc }
    if (-not (Test-LabFirewallSnapshotTaken -Action 'default_deny_in')) { return 20 }
    $rc = Test-LabFirewallScoringCovered
    if ($rc -ne 0) { return $rc }
    try {
        Add-LabManifestEntry -Action firewall_default_deny -Target 'windows'
        foreach ($icmp in @('ICMPv4', 'ICMPv6')) {
            $name = "Labyrinth: allow $icmp"
            if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $name -Group $script:LabFirewallGroup -Direction Inbound -Action Allow `
                    -Protocol $icmp -Profile Any -ErrorAction Stop | Out-Null
            }
        }
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultInboundAction Block `
            -AllowInboundRules True -ErrorAction Stop
        Write-LabLog -EventName firewall_default_deny -Message 'set the Windows Firewall inbound default to block'
    } catch {
        Write-LabFirewallError "the default deny failed: $($_.Exception.Message)"
        return 40
    }
    return 0
}

# Undo-LabFirewallChange: restore, newest first, every snapshot the current
# module took in the current run. Safe to run repeatedly.
function Undo-LabFirewallChange {
    $worst = 0
    foreach ($dir in @(Get-LabFirewallSnapshotList)) {
        $rc = Restore-LabFirewallSnapshot -Path $dir
        if ($rc -gt $worst) { $worst = $rc }
    }
    return $worst
}
