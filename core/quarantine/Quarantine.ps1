#Requires -Version 5.1
# core/quarantine/Quarantine.ps1: quarantine, never delete (design 17,
# section 5.1). Dot-sourced through core/Lab.ps1.
#
# Each function takes an item and the reason the module gives for it, records
# the step in the run manifest, then disables the item and keeps what is
# needed to put it back under <backup>\quarantine\<run>\<seq>\. The helper
# does not judge an item: the module decides its class (design 17, section
# 4). Undo-LabQuarantine undoes the current module's entries, newest first.
#
# Each function returns 0 done (or the item is already gone), 20 refused or
# 40 error. The reason goes to standard error.

function Write-LabQuarantineError {
    param([Parameter(Mandatory)] [string] $Message)
    [Console]::Error.WriteLine("quarantine: $Message")
}

# Get-LabQuarantineDir [-Seq N]: <backup>\quarantine\<run>[\<seq>].
function Get-LabQuarantineDir {
    param([string] $Seq)
    $dir = Join-Path (Join-Path $env:LAB_BACKUP_DIR 'quarantine') $env:LAB_RUN_ID
    if ($Seq) { $dir = Join-Path $dir $Seq }
    return $dir
}

function Test-LabQuarantineChange {
    param([Parameter(Mandatory)] [string] $Action)
    if ($env:LAB_DRY_RUN -ne '0') {
        Write-LabQuarantineError "$Action is refused in plan mode"
        return $false
    }
    return $true
}

# Test-LabQuarantinePath PATH: absolute, without '..', outside Labyrinth's tree.
function Test-LabQuarantinePath {
    param([Parameter(Mandatory)] [string] $Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '(^|\\)\.\.(\\|$)') {
        Write-LabQuarantineError "path must be absolute, without '..': $Path"
        return $false
    }
    foreach ($d in @($env:LAB_ROOT, $env:LAB_STATE_DIR, $env:LAB_BACKUP_DIR, $env:LAB_LOG_DIR, $env:LAB_CONFIG_DIR)) {
        if (-not $d) { continue }
        $root = $d.TrimEnd('\')
        if ($Path -ieq $root -or $Path.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-LabQuarantineError "refusing a path inside Labyrinth's own tree: $Path"
            return $false
        }
    }
    return $true
}

# Move-LabQuarantineFile -Path P -Reason R: move a file aside.
function Move-LabQuarantineFile {
    param([Parameter(Mandatory)] [string] $Path, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "quarantine of $Path")) { return 20 }
    if (-not (Test-LabQuarantinePath -Path $Path)) { return 20 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Write-LabQuarantineError "refusing a folder (list it for a person): $Path"
        return 20
    }
    try {
        $dest = Join-Path (Get-LabQuarantineDir -Seq ([string](Get-LabManifestNextSeq))) ($Path -replace ':', '')
        $sum = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        Add-LabManifestEntry -Action quarantine_file -Target $Path -Backup $dest -Prev $sum -Note $Reason
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    } catch {
        Write-LabQuarantineError "could not quarantine ${Path}: $($_.Exception.Message)"
        return 40
    }
    # A file that cannot be moved (locked or denied) is one item left for a
    # person, not an error that stops the whole sweep.
    try {
        Move-Item -LiteralPath $Path -Destination $dest -ErrorAction Stop
    } catch {
        Write-LabQuarantineError "could not move ${Path} (locked or denied?); list it for a person: $($_.Exception.Message)"
        return 20
    }
    try { Write-LabLog -EventName quarantine_file -Message "quarantined ${Path}: $Reason" } catch { Write-Verbose 'log not written' }
    return 0
}

function Restore-LabQuarantineFile {
    param($Entry)
    $target = $Entry.target
    $backup = $Entry.backup
    if (-not (Test-Path -LiteralPath $backup)) {
        if (Test-Path -LiteralPath $target) { return 0 }
        Write-LabQuarantineError "quarantined copy missing: $backup"
        return 40
    }
    if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Entry.prev) {
        Write-LabQuarantineError "the quarantined copy of $target has changed; restore it by hand from $backup"
        return 40
    }
    if (Test-Path -LiteralPath $target) {
        $aside = Join-Path (Get-LabQuarantineDir) ('aside-{0}\{1}' -f $Entry.seq, ($target -replace ':', ''))
        New-Item -ItemType Directory -Path (Split-Path -Parent $aside) -Force | Out-Null
        Move-Item -LiteralPath $target -Destination $aside
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Move-Item -LiteralPath $backup -Destination $target
    return 0
}

# Disable-LabQuarantineTask -TaskPath P -TaskName N -Reason R: export the
# task to XML, then disable it.
function Disable-LabQuarantineTask {
    param([Parameter(Mandatory)] [string] $TaskPath, [Parameter(Mandatory)] [string] $TaskName, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "quarantine of task $TaskPath$TaskName")) { return 20 }
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 0 }
    try {
        $dir = Get-LabQuarantineDir -Seq ([string](Get-LabManifestNextSeq))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $xml = Join-Path $dir 'task.xml'
        [IO.File]::WriteAllText($xml, (Export-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop))
        $was = 'enabled'
        if ("$($task.State)" -eq 'Disabled') { $was = 'disabled' }
        Add-LabManifestEntry -Action quarantine_task -Target "$TaskPath$TaskName" -Backup $xml -Prev $was -Note $Reason
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-LabLog -EventName quarantine_task -Message "disabled task $TaskPath${TaskName}: $Reason"
    } catch {
        Write-LabQuarantineError "could not quarantine task $TaskPath${TaskName}: $($_.Exception.Message)"
        return 40
    }
    return 0
}

function Restore-LabQuarantineTask {
    param($Entry)
    $i = $Entry.target.LastIndexOf('\')
    $path = $Entry.target.Substring(0, $i + 1)
    $name = $Entry.target.Substring($i + 1)
    if (-not (Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue)) {
        Register-ScheduledTask -TaskPath $path -TaskName $name -Xml ([IO.File]::ReadAllText($Entry.backup)) -ErrorAction Stop | Out-Null
    }
    if ($Entry.prev -ceq 'enabled') {
        Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
    }
    return 0
}

# Disable-LabQuarantineService -Name N -Reason R: record the start mode, set
# it to Disabled and stop the service. Dependent services are not stopped.
function Disable-LabQuarantineService {
    param([Parameter(Mandatory)] [string] $Name, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "quarantine of service $Name")) { return 20 }
    if ($Name -notmatch '^[A-Za-z0-9_.$ -]+$') { Write-LabQuarantineError "not a service name: $Name"; return 40 }
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { return 0 }
    try {
        $prev = 'start={0} delayed={1} running={2}' -f $svc.StartMode, [bool]$svc.DelayedAutoStart, ($svc.State -eq 'Running')
        Add-LabManifestEntry -Action quarantine_service -Target $Name -Prev $prev -Note $Reason
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        if ($svc.State -ne 'Stopped') { Stop-Service -Name $Name -ErrorAction Stop }
        Write-LabLog -EventName quarantine_service -Message "disabled and stopped service ${Name}: $Reason"
    } catch {
        Write-LabQuarantineError "could not quarantine service ${Name}: $($_.Exception.Message)"
        return 40
    }
    return 0
}

function Restore-LabQuarantineService {
    param($Entry)
    if ($Entry.prev -notmatch '^start=(\w+) delayed=(\w+) running=(\w+)$') { throw "bad record for service $($Entry.target)" }
    $mode = @{ Auto = 'Automatic'; Manual = 'Manual'; Disabled = 'Disabled' }[$Matches[1]]
    $delayed = $Matches[2] -eq 'True'
    $running = $Matches[3] -eq 'True'
    if (-not $mode) { throw "start mode $($Matches[1]) of $($Entry.target) must be restored by hand" }
    Set-Service -Name $Entry.target -StartupType $mode -ErrorAction Stop
    if ($delayed) {
        & sc.exe config $Entry.target start= delayed-auto | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe could not set delayed start on $($Entry.target)" }
    }
    if ($running) { Start-Service -Name $Entry.target -ErrorAction Stop }
    return 0
}

# Values whose removal would stop every logon. A person sets them back to the
# default after approval instead (design 17, section 5.1).
$script:LabQuarantineKeepValues = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon|Userinit',
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon|Shell'
)

# Move-LabQuarantineRegistryValue -Path P -Name N -Reason R: export the
# value's name, kind and data, then remove the value.
function Move-LabQuarantineRegistryValue {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "quarantine of $Path\$Name")) { return 20 }
    if ($script:LabQuarantineKeepValues -contains "$($Path.TrimEnd('\'))|$Name") {
        Write-LabQuarantineError "refusing to remove $Path\$Name, which every logon needs; set it back to its default after approval"
        return 20
    }
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key -or $key.GetValueNames() -notcontains $Name) { return 0 }
    try {
        $kind = $key.GetValueKind($Name)
        $data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary) { $data = [Convert]::ToBase64String([byte[]]$data) }
        $dir = Get-LabQuarantineDir -Seq ([string](Get-LabManifestNextSeq))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir 'value.json'
        $record = [ordered]@{ path = $Path; name = $Name; kind = "$kind"; data = $data }
        [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $record -Depth 3))
        Add-LabManifestEntry -Action quarantine_registry -Target "$Path\$Name" -Backup $file -Prev "$kind" -Note $Reason
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        Write-LabLog -EventName quarantine_registry -Message "removed registry value $Path\${Name}: $Reason"
    } catch {
        Write-LabQuarantineError "could not quarantine $Path\${Name}: $($_.Exception.Message)"
        return 40
    }
    return 0
}

function Restore-LabQuarantineRegistryValue {
    param($Entry)
    $r = [IO.File]::ReadAllText($Entry.backup) | ConvertFrom-Json
    $data = $r.data
    switch ($r.kind) {
        'Binary' { $data = [Convert]::FromBase64String($data) }
        'MultiString' { $data = [string[]]@($data) }
    }
    $key = Get-Item -LiteralPath $r.path -ErrorAction SilentlyContinue
    if (-not $key) { New-Item -Path $r.path -Force | Out-Null }
    New-ItemProperty -LiteralPath $r.path -Name $r.name -PropertyType $r.kind -Value $data -Force -ErrorAction Stop | Out-Null
    return 0
}

# Move-LabQuarantineWmiBinding -FilterName F -ConsumerName C -Reason R: export
# the binding, its filter and its consumer, then remove only the binding,
# which stops the subscription.
function Move-LabQuarantineWmiBinding {
    param([Parameter(Mandatory)] [string] $FilterName, [Parameter(Mandatory)] [string] $ConsumerName, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "quarantine of WMI binding $FilterName -> $ConsumerName")) { return 20 }
    $binding = @(Get-CimInstance -Namespace 'root/subscription' -ClassName '__FilterToConsumerBinding' -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter.Name -ceq $FilterName -and $_.Consumer.Name -ceq $ConsumerName })
    if ($binding.Count -eq 0) { return 0 }
    try {
        $dir = Get-LabQuarantineDir -Seq ([string](Get-LabManifestNextSeq))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $filter = Get-CimInstance -Namespace 'root/subscription' -ClassName '__EventFilter' -Filter "Name='$($FilterName -replace "'", "''")'" -ErrorAction Stop
        $consumerClass = $binding[0].Consumer.CimClass.CimClassName
        $consumer = Get-CimInstance -Namespace 'root/subscription' -ClassName $consumerClass -Filter "Name='$($ConsumerName -replace "'", "''")'" -ErrorAction Stop
        Export-Clixml -LiteralPath (Join-Path $dir 'binding.xml') -InputObject $binding[0]
        Export-Clixml -LiteralPath (Join-Path $dir 'filter.xml') -InputObject $filter
        Export-Clixml -LiteralPath (Join-Path $dir 'consumer.xml') -InputObject $consumer
        Add-LabManifestEntry -Action quarantine_wmi -Target "$FilterName -> $ConsumerName" -Backup $dir -Prev $consumerClass -Note $Reason
        $binding[0] | Remove-CimInstance -ErrorAction Stop
        Write-LabLog -EventName quarantine_wmi -Message "removed WMI binding $FilterName -> ${ConsumerName}: $Reason"
    } catch {
        Write-LabQuarantineError "could not quarantine WMI binding $FilterName -> ${ConsumerName}: $($_.Exception.Message)"
        return 40
    }
    return 0
}

function Restore-LabQuarantineWmiBinding {
    param($Entry)
    $filterName, $consumerName = $Entry.target -split ' -> ', 2
    $existing = @(Get-CimInstance -Namespace 'root/subscription' -ClassName '__FilterToConsumerBinding' -ErrorAction SilentlyContinue |
            Where-Object { $_.Filter.Name -ceq $filterName -and $_.Consumer.Name -ceq $consumerName })
    if ($existing.Count -gt 0) { return 0 }
    $filter = Get-CimInstance -Namespace 'root/subscription' -ClassName '__EventFilter' -Filter "Name='$($filterName -replace "'", "''")'" -ErrorAction Stop
    $consumer = Get-CimInstance -Namespace 'root/subscription' -ClassName $Entry.prev -Filter "Name='$($consumerName -replace "'", "''")'" -ErrorAction Stop
    if (-not $filter -or -not $consumer) { throw "the filter or consumer of $($Entry.target) is gone; restore it by hand from $($Entry.backup)" }
    New-CimInstance -Namespace 'root/subscription' -ClassName '__FilterToConsumerBinding' `
        -Property @{ Filter = [ref]$filter; Consumer = [ref]$consumer } -ErrorAction Stop | Out-Null
    return 0
}

# Test-LabQuarantineOwnProcess ID: is ID this process or one of its parents?
function Test-LabQuarantineOwnProcess {
    param([Parameter(Mandatory)] [int] $Id)
    $p = $PID
    $seen = @{}
    while ($p -and -not $seen.ContainsKey($p)) {
        if ($p -eq $Id) { return $true }
        $seen[$p] = $true
        $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        $p = [int]$proc.ParentProcessId
    }
    return $false
}

# Invoke-LabQuarantineProcess -Id N -Reason R: end a process an item started.
# This cannot be restored; restoring the item restarts it if it is a service
# that was running.
function Invoke-LabQuarantineProcess {
    param([Parameter(Mandatory)] [int] $Id, [string] $Reason = '')
    if (-not (Test-LabQuarantineChange -Action "ending process $Id")) { return 20 }
    if ($Id -le 4 -or (Test-LabQuarantineOwnProcess -Id $Id)) {
        Write-LabQuarantineError "refusing to end process $Id"
        return 20
    }
    $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
    if (-not $proc) { return 0 }
    try {
        Add-LabManifestEntry -Action quarantine_process -Target ([string]$Id) -Prev ([string]$proc.CommandLine -replace '[\x00-\x1f\x7f]', ' ') -Note $Reason
        Stop-Process -Id $Id -Force -ErrorAction Stop
        Write-LabLog -EventName quarantine_process -Message "ended process $Id ($($proc.Name)): $Reason"
    } catch {
        Write-LabQuarantineError "could not end process ${Id}: $($_.Exception.Message)"
        return 40
    }
    return 0
}

# Undo-LabQuarantine: undo the current module's quarantine entries in the
# current run, newest first. Safe to run repeatedly.
function Undo-LabQuarantine {
    $entries = @(Get-LabManifestEntry | Where-Object { $_.module -ceq $env:LAB_MODULE_ID })
    [array]::Reverse($entries)
    $worst = 0
    foreach ($e in $entries) {
        $rc = 0
        try {
            switch ($e.action) {
                'quarantine_file' { $rc = Restore-LabQuarantineFile -Entry $e }
                'quarantine_task' { $rc = Restore-LabQuarantineTask -Entry $e }
                'quarantine_service' { $rc = Restore-LabQuarantineService -Entry $e }
                'quarantine_registry' { $rc = Restore-LabQuarantineRegistryValue -Entry $e }
                'quarantine_wmi' { $rc = Restore-LabQuarantineWmiBinding -Entry $e }
            }
        } catch {
            Write-LabQuarantineError "could not restore $($e.target) ($($e.action)): $($_.Exception.Message)"
            $rc = 40
        }
        if ($rc -gt $worst) { $worst = $rc }
    }
    return $worst
}
