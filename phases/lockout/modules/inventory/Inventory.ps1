#Requires -Version 5.1
# Inventory.ps1: the functions of lockout.inventory (design 08, section 3.1),
# dot-sourced by check.ps1 and plan.ps1. Loading it only defines functions.
#
# The functions that decide things take plain objects (sockets, processes,
# service rows), so the tests feed them fixtures; the Get-InvCollected*
# functions that read the system are thin. Nothing here changes the host: the
# only writes are the inventory and the dependency map under the state
# folder, and only when the runner says this is a run (LAB_DRY_RUN=0,
# design 00, section 4). Registry keys are only read.

$script:InvOut = New-Object Text.StringBuilder
$script:InvCount = @{}
$script:InvNote = @()
$script:InvMapNote = ''
$script:InvMapAll = @()
$script:InvNumberKey = @('port', 'pid', 'uid', 'local_port', 'remote_port')

# Add-InvNote TEXT: something that could not be recorded; check prints it as
# a found: line, and one missing source never stops the rest.
function Add-InvNote {
    param([string] $Text)
    $script:InvNote += $Text
}

# Add-InvRecord KIND FIELDS: append one JSON record to the inventory. Keys in
# InvNumberKey are numbers; every other value is a string.
function Add-InvRecord {
    param([string] $Kind, [System.Collections.Specialized.OrderedDictionary] $Field)
    $parts = @('"kind":' + (ConvertTo-LabJsonString $Kind))
    foreach ($k in $Field.Keys) {
        $v = "$($Field[$k])"
        if ($script:InvNumberKey -contains $k) {
            if ($v -match '^[0-9]+$') { $parts += ('"{0}":{1}' -f $k, [int64]$v) } else { $parts += ('"{0}":null' -f $k) }
        } else {
            $parts += ('"{0}":{1}' -f $k, (ConvertTo-LabJsonString $v))
        }
    }
    [void]$script:InvOut.Append('{' + ($parts -join ',') + "}`n")
    if (-not $script:InvCount.ContainsKey($Kind)) { $script:InvCount[$Kind] = 0 }
    $script:InvCount[$Kind]++
}

# Get-InvExecutable COMMANDLINE: the program of a command line, without its
# arguments, which could hold a secret.
function Get-InvExecutable {
    param([AllowEmptyString()] [AllowNull()] [string] $CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $s = $CommandLine.Trim()
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 0) { return $s.Substring(1, $end - 1) }
        return $s.Substring(1)
    }
    $m = [regex]::Match($s, '^[A-Za-z]:\\.*?\.(exe|bat|cmd|com|ps1|vbs|js|msc|dll)', 'IgnoreCase')
    if ($m.Success) { return $m.Value }
    return ($s -split '\s+', 2)[0]
}

# Get-InvFingerprint BASE64: an authorized key's fingerprint, SHA256: and the
# unpadded base64 of the digest of the key's blob, as ssh-keygen prints it.
# The key itself is never kept. Returns '' when the text is not base64.
function Get-InvFingerprint {
    param([AllowEmptyString()] [string] $Base64)
    try {
        $blob = [Convert]::FromBase64String($Base64)
    } catch { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($blob) } finally { $sha.Dispose() }
    return 'SHA256:' + [Convert]::ToBase64String($digest).TrimEnd('=')
}

# Read-InvAuthorizedKey USER FILE TEXT: one key record per authorized key.
function Read-InvAuthorizedKey {
    param([string] $User, [string] $File, [AllowEmptyString()] [string] $Text)
    # Options before the key type may hold quoted text with spaces
    # (command="exec ssh-agent bash"): they are skipped a token at a time, a
    # quoted string counting as part of its token.
    $keyRe = '^(?:(?:[^\s"]|"(?:[^"\\]|\\.)*")+\s+)*?(?<type>(?:ssh-|ecdsa-|sk-|rsa-sha2-)\S*)\s+(?<blob>\S+)(?:\s+(?<comment>.*))?$'
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $m = [regex]::Match($line, $keyRe)
        if (-not $m.Success) { continue }
        Add-InvRecord 'key' ([ordered]@{
                user = $User; file = $File; type = $m.Groups['type'].Value
                fingerprint = (Get-InvFingerprint $m.Groups['blob'].Value); comment = $m.Groups['comment'].Value.Trim()
            })
    }
}

# Format-InvAddress ADDRESS: lower case, with an IPv4-mapped IPv6 address
# shown as plain IPv4 and a zone id dropped.
function Format-InvAddress {
    param([AllowEmptyString()] [AllowNull()] [string] $Address)
    if ($null -eq $Address) { return '' }
    $a = $Address.ToLowerInvariant()
    $a = $a -replace '%.*$', ''
    if ($a -match '^::ffff:(\d+\.\d+\.\d+\.\d+)$') { $a = $Matches[1] }
    return $a
}

# Test-InvLocalAddress ADDRESS: loopback, or no address at all (wildcard).
function Test-InvLocalAddress {
    param([AllowEmptyString()] [AllowNull()] [string] $Address)
    $a = Format-InvAddress $Address
    return ($a -eq '' -or $a -eq '*' -or $a -eq '::' -or $a -eq '::1' -or $a -eq '0.0.0.0' -or $a.StartsWith('127.'))
}

# Test-InvListener SOCKET: does the socket wait for others? A TCP socket in
# LISTEN, or a UDP socket with no peer (UNCONN). A socket object has Proto
# (tcp or udp), State (LISTEN, UNCONN, ESTAB...), LocalAddress, LocalPort,
# RemoteAddress, RemotePort and ProcessId.
function Test-InvListener {
    param($Socket)
    return (($Socket.Proto -eq 'tcp' -and $Socket.State -eq 'LISTEN') -or ($Socket.Proto -eq 'udp' -and $Socket.State -eq 'UNCONN'))
}

# Get-InvDescendant PROCESSES SEED: each seed process id and every process
# below it. A process object has ProcessId, ParentProcessId and Name.
function Get-InvDescendant {
    param($Process, [int[]] $Seed)
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($s in $Seed) { [void]$set.Add($s) }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($p in @($Process)) {
            if (-not $set.Contains([int]$p.ProcessId) -and $set.Contains([int]$p.ParentProcessId)) {
                [void]$set.Add([int]$p.ProcessId)
                $changed = $true
            }
        }
    }
    return @($set | Sort-Object)
}

# Read-InvIisBinding TEXT: the HTTP and HTTPS bindings of every IIS site, from
# the text of applicationHost.config, as objects with Site, Port and Pool (the
# site's application pool). Nothing for text with no sites.
function Read-InvIisBinding {
    param([AllowEmptyString()] [string] $Text)
    $found = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $found }
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml($Text)
    foreach ($site in @($xml.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
        $pool = 'DefaultAppPool'
        $defaults = $site.SelectSingleNode('applicationDefaults')
        if ($defaults -and $defaults.GetAttribute('applicationPool')) { $pool = $defaults.GetAttribute('applicationPool') }
        $root = $site.SelectSingleNode("application[@path='/']")
        if ($root -and $root.GetAttribute('applicationPool')) { $pool = $root.GetAttribute('applicationPool') }
        foreach ($b in @($site.SelectNodes('bindings/binding'))) {
            $proto = $b.GetAttribute('protocol')
            if ($proto -ne 'http' -and $proto -ne 'https') { continue }
            $m = [regex]::Match($b.GetAttribute('bindingInformation'), ':(\d+):[^:]*$')
            if (-not $m.Success) { continue }
            $found += [pscustomobject]@{ Site = $site.GetAttribute('name'); Port = [int]$m.Groups[1].Value; Pool = $pool }
        }
    }
    return $found
}

# Get-InvIisProcessId BINDINGS PORT PROCESSES: the w3wp.exe worker processes
# that serve the IIS site bound to PORT: the ones whose command line names
# that site's application pool (-ap "pool"). Nothing when no site is bound to
# PORT, or no worker for its pool is running.
function Get-InvIisProcessId {
    param($Binding, [int] $Port, $Process)
    $pools = @(@($Binding) | Where-Object { $_ -and [int]$_.Port -eq $Port } | ForEach-Object { $_.Pool } | Sort-Object -Unique)
    $seed = @()
    foreach ($p in @($Process)) {
        if ("$($p.Name)" -ine 'w3wp.exe') { continue }
        foreach ($pool in $pools) {
            if ("$($p.CommandLine)" -match ('(?i)-ap\s+"?' + [regex]::Escape($pool) + '"?(\s|$)')) { $seed += [int]$p.ProcessId; break }
        }
    }
    return $seed
}

# Test-InvSystemListener SOCKETS PORT PROTOS: is the listener on PORT owned by
# the System process (id 4), as with HTTP.sys, SMB or WinRM?
function Test-InvSystemListener {
    param($Socket, [int] $Port, [string[]] $Proto)
    foreach ($s in @($Socket)) {
        if ([int]$s.LocalPort -eq $Port -and $Proto -contains $s.Proto -and (Test-InvListener $s) -and [int]$s.ProcessId -eq 4) { return $true }
    }
    return $false
}

# Get-InvServiceProcessId SOCKETS PORT PROTOS PROCESSES: the processes of the
# scored service that listens on PORT (design 08, section 3.1): the listener's
# service process and its descendants; for a listener that is the System
# process (id 4, where HTTP.sys serves an IIS site), the w3wp.exe workers of
# the site bound to PORT (IISBINDING, from Read-InvIisBinding) and their
# descendants. Nothing when nothing listens on PORT or the System listener
# is not an IIS site binding (SMB, WinRM).
function Get-InvServiceProcessId {
    param($Socket, [int] $Port, [string[]] $Proto, $Process, $IisBinding = $null)
    $seed = @()
    foreach ($s in @($Socket)) {
        if ([int]$s.LocalPort -ne $Port -or $Proto -notcontains $s.Proto -or -not (Test-InvListener $s)) { continue }
        $owner = [int]$s.ProcessId
        if ($owner -eq 4) {
            $seed += @(Get-InvIisProcessId $IisBinding $Port $Process)
        } elseif ($owner -gt 0) {
            $seed += $owner
        }
    }
    if ($seed.Count -eq 0) { return @() }
    return @(Get-InvDescendant $Process ($seed | Sort-Object -Unique))
}

# Get-InvOutbound SOCKETS PROCESSID LISTENPORT PROCESSES: the outbound
# connections of the given processes, as objects with Address, Proto, Port and
# Process, without repeats. Outbound means an established TCP connection or a
# connected UDP socket whose remote address is not loopback and whose local
# port is not one the host listens on (design 08, section 3.1).
function Get-InvOutbound {
    param($Socket, [int[]] $ProcessId, [int[]] $ListenPort, $Process)
    $names = @{}
    foreach ($p in @($Process)) { $names[[int]$p.ProcessId] = "$($p.Name)" }
    $seen = @{}
    foreach ($s in @($Socket)) {
        if ($s.State -ne 'ESTAB' -or $ProcessId -notcontains [int]$s.ProcessId) { continue }
        if ($ListenPort -contains [int]$s.LocalPort) { continue }
        if (Test-InvLocalAddress $s.RemoteAddress) { continue }
        $name = ''
        if ($names.ContainsKey([int]$s.ProcessId)) { $name = $names[[int]$s.ProcessId] -replace '\s', '_' }
        $addr = Format-InvAddress $s.RemoteAddress
        $key = "$addr $($s.Proto) $([int]$s.RemotePort)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{ Address = $addr; Proto = $s.Proto; Port = [int]$s.RemotePort; Process = $name }
    }
}

# Get-InvMapLine SERVICES SOCKETS PROCESSES: the "service address proto port
# process" line of every outbound connection a scored service has open now.
# A service object has Name, Proto and Port; dns is looked for over tcp and udp.
function Get-InvMapLine {
    param($Service, $Socket, $Process, $IisBinding = $null)
    $listenPorts = @(@($Socket) | Where-Object { Test-InvListener $_ } | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
    foreach ($svc in @($Service)) {
        $protos = @('tcp')
        if ($svc.Proto -eq 'dns') { $protos = @('tcp', 'udp') }
        $pids = @(Get-InvServiceProcessId $Socket ([int]$svc.Port) $protos $Process $IisBinding)
        if ($pids.Count -eq 0) {
            if (Test-InvSystemListener $Socket ([int]$svc.Port) $protos) {
                Add-InvNote "scored service $($svc.Name) (port $($svc.Port)) is held by the System process, and no IIS site binding on that port could be matched to a worker, so its connections were not mapped"
            }
            continue
        }
        foreach ($o in @(Get-InvOutbound $Socket $pids $listenPorts $Process | Sort-Object Address, Proto, Port)) {
            '{0} {1} {2} {3} {4}' -f $svc.Name, $o.Address, $o.Proto, $o.Port, $o.Process
        }
    }
}

# Merge-InvMap PATH LINES: add each "service address proto port process" line
# to the file unless its first four columns are already there. Existing lines
# are never changed or removed. Returns the lines it added. With no PATH it
# only reports what would be added.
function Merge-InvMap {
    param([AllowEmptyString()] [string] $Path, [string[]] $Line)
    $have = @{}
    if ($Path -ne '' -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        foreach ($raw in [IO.File]::ReadAllLines($Path)) {
            $t = ($raw -replace '#.*$', '').Trim()
            $w = @($t -split '\s+')
            if ($w.Count -ge 4 -and $t -ne '') { $have["$($w[0]) $($w[1]) $($w[2]) $($w[3])"] = $true }
        }
    }
    $new = @()
    foreach ($l in @($Line)) {
        if ($null -eq $l -or "$l".Trim() -eq '') { continue }
        $w = @("$l".Trim() -split '\s+')
        $key = "$($w[0]) $($w[1]) $($w[2]) $($w[3])"
        if ($have.ContainsKey($key)) { continue }
        $have[$key] = $true
        $new += "$l".Trim()
    }
    if ($Path -ne '') {
        # A hand-edited file may lack its final newline: add it first, or the
        # first new line would join the last old one.
        if ($new.Count -gt 0 -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $bytes = [IO.File]::ReadAllBytes($Path)
            if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { [IO.File]::AppendAllText($Path, "`n") }
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Add-LabTextLine $Path '# service  address  proto  port  process'
            Add-LabTextLine $Path '# Written by lockout.inventory; same columns as outbound-allow. Lines are only ever added.'
        }
        foreach ($l in $new) { Add-LabTextLine $Path $l }
    }
    return $new
}

# ----------------------------------------------------------- system readers

# Get-InvCollectedProcess: every process, as ProcessId, ParentProcessId, Name
# and CommandLine (read only to tell IIS workers apart; never recorded).
function Get-InvCollectedProcess {
    @(Get-CimInstance -ClassName Win32_Process | ForEach-Object {
            [pscustomobject]@{ ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId; Name = "$($_.Name)"; CommandLine = "$($_.CommandLine)" }
        })
}

# Get-InvCollectedSocket: the TCP connections and UDP endpoints, as socket
# objects (see Test-InvListener). Windows lists no connected UDP sockets.
function Get-InvCollectedSocket {
    $all = @()
    try {
        foreach ($c in @(Get-NetTCPConnection -ErrorAction Stop)) {
            $state = 'OTHER'
            if ("$($c.State)" -eq 'Listen') { $state = 'LISTEN' } elseif ("$($c.State)" -eq 'Established') { $state = 'ESTAB' }
            $all += [pscustomobject]@{
                Proto = 'tcp'; State = $state; LocalAddress = "$($c.LocalAddress)"; LocalPort = [int]$c.LocalPort
                RemoteAddress = "$($c.RemoteAddress)"; RemotePort = [int]$c.RemotePort; ProcessId = [int]$c.OwningProcess
            }
        }
    } catch { Add-InvNote 'Get-NetTCPConnection failed, so TCP listeners and connections were not recorded' }
    try {
        foreach ($u in @(Get-NetUDPEndpoint -ErrorAction Stop)) {
            $all += [pscustomobject]@{
                Proto = 'udp'; State = 'UNCONN'; LocalAddress = "$($u.LocalAddress)"; LocalPort = [int]$u.LocalPort
                RemoteAddress = ''; RemotePort = 0; ProcessId = [int]$u.OwningProcess
            }
        }
    } catch { Add-InvNote 'Get-NetUDPEndpoint failed, so UDP listeners were not recorded' }
    return $all
}

function Add-InvCollectedAccount {
    try {
        foreach ($u in @(Get-LocalUser -ErrorAction Stop)) {
            Add-InvRecord 'user' ([ordered]@{
                    name = "$($u.Name)"; sid = "$($u.SID)"; enabled = "$($u.Enabled)"
                    password_required = "$($u.PasswordRequired)"; last_logon = "$($u.LastLogon)"
                })
        }
    } catch { Add-InvNote 'local accounts could not be listed (this may be a domain controller), so users were not recorded' }
    try {
        foreach ($g in @(Get-LocalGroup -ErrorAction Stop)) {
            $members = ''
            try { $members = (@(Get-LocalGroupMember -Group $g.Name -ErrorAction Stop) | ForEach-Object { "$($_.Name)" }) -join ',' } catch { $members = '' }
            Add-InvRecord 'group' ([ordered]@{ name = "$($g.Name)"; sid = "$($g.SID)"; members = $members })
        }
    } catch { Add-InvNote 'local groups could not be listed, so groups were not recorded' }
}

function Add-InvCollectedKey {
    $files = @()
    $admin = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    if (Test-Path -LiteralPath $admin -PathType Leaf) { $files += [pscustomobject]@{ User = 'administrators'; Path = $admin } }
    $users = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $users -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $users -Directory -ErrorAction SilentlyContinue)) {
            $f = Join-Path $d.FullName '.ssh\authorized_keys'
            if (Test-Path -LiteralPath $f -PathType Leaf) { $files += [pscustomobject]@{ User = $d.Name; Path = $f } }
        }
    }
    foreach ($f in $files) {
        try { Read-InvAuthorizedKey $f.User $f.Path ([IO.File]::ReadAllText($f.Path)) }
        catch { Add-InvNote "$($f.Path) cannot be read" }
    }
}

function Add-InvCollectedSocketRecord {
    param($Socket, $Process, $Service)
    $names = @{}
    foreach ($p in @($Process)) { $names[[int]$p.ProcessId] = "$($p.Name)" }
    $svcOf = @{}
    foreach ($s in @($Service)) { if ([int]$s.ProcessId -gt 0 -and -not $svcOf.ContainsKey([int]$s.ProcessId)) { $svcOf[[int]$s.ProcessId] = "$($s.Name)" } }
    $seen = @{}
    foreach ($s in @($Socket)) {
        $pname = ''
        if ($names.ContainsKey([int]$s.ProcessId)) { $pname = $names[[int]$s.ProcessId] }
        if (Test-InvListener $s) {
            $key = "$($s.Proto) $($s.LocalAddress) $($s.LocalPort) $($s.ProcessId)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $svc = ''
            if ($svcOf.ContainsKey([int]$s.ProcessId)) { $svc = $svcOf[[int]$s.ProcessId] }
            Add-InvRecord 'listener' ([ordered]@{
                    protocol = $s.Proto; address = (Format-InvAddress $s.LocalAddress); port = $s.LocalPort
                    process = $pname; pid = $s.ProcessId; service = $svc
                })
        } else {
            Add-InvRecord 'connection' ([ordered]@{
                    protocol = $s.Proto; state = $s.State; local_address = (Format-InvAddress $s.LocalAddress)
                    local_port = $s.LocalPort; remote_address = (Format-InvAddress $s.RemoteAddress)
                    remote_port = $s.RemotePort; process = $pname; pid = $s.ProcessId
                })
        }
    }
}

function Add-InvCollectedService {
    param($Service)
    foreach ($s in @($Service)) {
        Add-InvRecord 'service' ([ordered]@{
                name = "$($s.Name)"; display_name = "$($s.DisplayName)"; state = "$($s.State)"
                start_mode = "$($s.StartMode)"; account = "$($s.StartName)"; pid = "$($s.ProcessId)"
                executable = (Get-InvExecutable "$($s.PathName)")
            })
    }
}

function Add-InvCollectedTask {
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            $exe = ''
            $first = @($t.Actions | Where-Object { $_.PSObject.Properties['Execute'] -and $_.Execute })
            if ($first.Count -gt 0) { $exe = Get-InvExecutable "$($first[0].Execute)" }
            Add-InvRecord 'task' ([ordered]@{
                    source = 'scheduled-task'; file = "$($t.TaskPath)$($t.TaskName)"; user = "$($t.Principal.UserId)"
                    schedule = "$($t.State)"; command = $exe; sha256 = ''
                })
        }
    } catch { Add-InvNote 'Get-ScheduledTask failed, so scheduled tasks were not recorded' }
}

function Add-InvCollectedStartup {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        try {
            $item = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            foreach ($p in $item.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                Add-InvRecord 'startup' ([ordered]@{ source = 'registry-run'; path = "$k\$($p.Name)"; command = (Get-InvExecutable "$($p.Value)") })
            }
        } catch { Add-InvNote "$k cannot be read" }
    }
    $folder = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
    if (Test-Path -LiteralPath $folder -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
            Add-InvRecord 'startup' ([ordered]@{ source = 'startup-folder'; path = $f.FullName; command = '' })
        }
    }
}

function Add-InvCollectedPackage {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $seen = @{}
    foreach ($k in $keys) {
        try {
            foreach ($p in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) {
                if (-not $p.PSObject.Properties['DisplayName'] -or -not $p.DisplayName) { continue }
                $version = ''
                if ($p.PSObject.Properties['DisplayVersion']) { $version = "$($p.DisplayVersion)" }
                $id = "$($p.DisplayName) $version"
                if ($seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                Add-InvRecord 'package' ([ordered]@{ name = "$($p.DisplayName)"; version = $version })
            }
        } catch { Add-InvNote 'installed programs could not be listed' }
    }
}

function Add-InvCollectedFirewall {
    try {
        foreach ($f in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            Add-InvRecord 'firewall' ([ordered]@{
                    tool = 'windows-firewall'
                    rule = "profile $($f.Name): enabled $($f.Enabled), inbound $($f.DefaultInboundAction), outbound $($f.DefaultOutboundAction)"
                })
        }
    } catch { Add-InvNote 'Get-NetFirewallProfile failed, so the firewall state was not recorded' }
}

# Get-InvServiceList: the scored services as objects with Name, Proto and
# Port, from the services file. $null, with InvMapNote set, when there are none.
function Get-InvServiceList {
    $script:InvMapNote = ''
    $list = $null
    try { $list = Read-LabServiceList } catch {
        $script:InvMapNote = 'the services file could not be read, so there is no dependency map'
        return $null
    }
    if ($null -eq $list) { $script:InvMapNote = 'there is no services file, so there is no dependency map' }
    return $list
}

# Get-InvCollectedAll: fill the inventory, and return the data the map needs.
function Get-InvCollectedAll {
    $script:InvOut = New-Object Text.StringBuilder
    $script:InvCount = @{}
    $script:InvNote = @()
    Add-InvCollectedAccount
    Add-InvCollectedKey
    $process = @()
    try { $process = @(Get-InvCollectedProcess) } catch { Add-InvNote 'Win32_Process could not be read, so process names are missing' }
    $service = @()
    try { $service = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop) } catch { Add-InvNote 'Win32_Service could not be read, so services were not recorded' }
    $socket = @(Get-InvCollectedSocket)
    Add-InvCollectedSocketRecord $socket $process $service
    Add-InvCollectedService $service
    Add-InvCollectedTask
    Add-InvCollectedStartup
    Add-InvCollectedPackage
    Add-InvCollectedFirewall
    $iis = @()
    $config = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
    if (Test-Path -LiteralPath $config -PathType Leaf) {
        try { $iis = @(Read-InvIisBinding ([IO.File]::ReadAllText($config))) } catch { Add-InvNote 'the IIS configuration could not be read, so IIS sites were not matched to their processes' }
    }
    return [pscustomobject]@{ Socket = $socket; Process = $process; Iis = $iis }
}

# Write-InvFound: the operator's found: lines (docs\Conventions.md section 3.2).
function Write-InvFound {
    $parts = @()
    foreach ($kind in 'user', 'group', 'sudoers', 'key', 'listener', 'service', 'task', 'startup', 'package', 'firewall', 'connection') {
        $n = 0
        if ($script:InvCount.ContainsKey($kind)) { $n = $script:InvCount[$kind] }
        $parts += "$n $kind"
    }
    Write-Output ('found: ' + ($parts -join ', '))
    foreach ($n in $script:InvNote) { Write-Output "found: note: $n" }
    if ($script:InvMapNote -ne '') { Write-Output "found: note: $($script:InvMapNote)" }
    foreach ($l in $script:InvMapAll) { Write-Output "found: dependency: $l" }
}

# Write-InvState: write the inventory file and merge the map (a run only).
# Writes did: lines. Throws when the state folder cannot be written.
function Write-InvState {
    $dir = Join-Path $env:LAB_STATE_DIR 'inventory'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z')
    $file = Join-Path $dir "$stamp.jsonl"
    $n = 1
    while (Test-Path -LiteralPath $file) { $n++; $file = Join-Path $dir "$stamp-$n.jsonl" }
    [IO.File]::WriteAllText($file, $script:InvOut.ToString(), (New-Object Text.UTF8Encoding $false))
    Write-Output "did: wrote the inventory to $file"
    if ($script:InvMapNote -ne '') { return }
    $deps = Join-Path $dir 'deps'
    $added = @(Merge-InvMap $deps $script:InvMapAll)
    Write-Output "did: added $($added.Count) line(s) to the dependency map $deps"
}
