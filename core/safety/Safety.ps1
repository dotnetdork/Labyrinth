#Requires -Version 5.1
# core/safety/Safety.ps1: the safety gates and run lock (design 03,
# sections 7 and 8). Dot-sourced through core/Lab.ps1. The parts that need
# Windows itself (administrator check, revert timer) are in System.ps1.

# Get-LabBreakGlass -Protected SET: the confirmed break-glass account, if one
# is recorded and is still a breakglass account in the protected set. It is
# asked once per host and kept until end-of-event cleanup.
function Get-LabBreakGlass {
    param([Parameter(Mandatory)] [hashtable] $Protected)
    $f = Join-Path $env:LAB_STATE_DIR 'breakglass'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    $line = @([IO.File]::ReadAllLines($f))
    if ($line.Count -eq 0) { return $null }
    $account = ($line[0] -split "`t", 2)[-1]
    if ($Protected[$account] -ceq 'breakglass') { return $account }
    return $null
}

# Save-LabBreakGlass -Protected SET -Account NAME: record that the operator
# confirmed NAME works at this host's console. NAME must be a breakglass account.
function Save-LabBreakGlass {
    param([Parameter(Mandatory)] [hashtable] $Protected, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Account)
    if ($Account -eq '' -or $Protected[$Account] -cne 'breakglass') {
        throw "break-glass: '$Account' is not a breakglass account in the protected set"
    }
    New-Item -ItemType Directory -Path $env:LAB_STATE_DIR -Force | Out-Null
    $f = Join-Path $env:LAB_STATE_DIR 'breakglass'
    [IO.File]::WriteAllText($f, "$(Get-LabUtcNow)`t$Account`n", (New-Object Text.UTF8Encoding $false))
}

# Enter-LabLock [-WaitSeconds N]: take the host's run lock, so two runs never
# change the same host at once. A lock whose holder is gone is taken over,
# and so is one whose process ID now belongs to another process (the lock
# records when its holder started). Returns $false if the lock is still held
# after N seconds.
function Enter-LabLock {
    param([int] $WaitSeconds = 0)
    $lock = Join-Path $env:LAB_STATE_DIR 'lock'
    $pidFile = Join-Path $lock 'pid'
    New-Item -ItemType Directory -Path $env:LAB_STATE_DIR -Force | Out-Null
    $waited = 0
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            break
        } catch {
            $found = Get-LabLockHolder
            $holder = $found.Id
            if ($found.State -eq 'gone') {
                Clear-LabLockFolder -Path $lock
                continue
            }
            if ($waited -ge $WaitSeconds) {
                [Console]::Error.WriteLine("labyrinth: another Labyrinth run (pid $holder) holds $lock")
                [Console]::Error.WriteLine("Wait for it to finish. If no Labyrinth run is going, delete $lock, then run the same command again.")
                return $false
            }
            Start-Sleep -Seconds 1
            $waited++
        }
    }
    [IO.File]::WriteAllText($pidFile, "$PID $(Get-LabProcessStart -Id $PID)`n")
    return $true
}

# Get-LabProcessStart -Id PID: when the process started, as UTC ticks, or ''
# when it is gone or its start time cannot be read.
function Get-LabProcessStart {
    param([Parameter(Mandatory)] [int] $Id)
    try {
        return [string](Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    } catch {
        return ''
    }
}

# Get-LabLockHolder: who the lock's pid file, "PID START", names: Id (the
# file's text when it holds no process ID) and State. State is 'none' with no
# pid file or no process ID in it; 'gone' when no process has the ID, or one
# has it but started at another time, so the ID was reused; 'live' when the
# process that took the lock is still there; and 'unknown' when a process
# has the ID but the lock records no start time, or the process's start
# time cannot be read, so this cannot be told.
function Get-LabLockHolder {
    $pidFile = Join-Path (Join-Path $env:LAB_STATE_DIR 'lock') 'pid'
    $found = @{ Id = ''; Start = ''; State = 'none' }
    if (-not (Test-Path -LiteralPath $pidFile)) { return $found }
    $text = ([IO.File]::ReadAllText($pidFile)).Trim()
    $found.Id = $text
    if ($text -notmatch '^(\d+)(?: (\d+))?$') { return $found }
    $found.Id = $Matches[1]
    $start = [string]$Matches[2]
    $found.Start = $start
    if (-not (Get-Process -Id ([int]$found.Id) -ErrorAction SilentlyContinue)) { $found.State = 'gone'; return $found }
    $now = Get-LabProcessStart -Id ([int]$found.Id)
    if ($start -eq '' -or $now -eq '') { $found.State = 'unknown' }
    elseif ($now -cne $start) { $found.State = 'gone' }
    else { $found.State = 'live' }
    return $found
}

# Get-LabDescendantId -ParentId PID -Since TIME: the process IDs below PID,
# children first. PID started at TIME, and only processes created since then
# count: Windows keeps a parent's ID on its children after the parent ends,
# so an older process naming PID is the child of an earlier owner of that ID.
function Get-LabDescendantId {
    param([int] $ParentId, [Parameter(Mandatory)] [datetime] $Since)
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue)) {
        if ($null -eq $p.CreationDate -or $p.CreationDate -lt $Since) { continue }
        Get-LabDescendantId -ParentId ([int]$p.ProcessId) -Since $p.CreationDate
        [int]$p.ProcessId
    }
}

# Close-LabLockHolder [-WaitSeconds N]: stop the live run that holds the lock
# and the entry points it started, waiting up to N seconds for it to end.
# The revert timer's rollback uses it, so it never undoes a run while that
# run is still changing the host. Only the process that took the lock is
# ever stopped: a process that merely has the recorded ID, started at another
# time, is left alone, and so is one whose start cannot be compared.
# Returns $false if the holder still lives.
function Close-LabLockHolder {
    param([int] $WaitSeconds = 30)
    $found = Get-LabLockHolder
    if ($found.State -eq 'none' -or $found.State -eq 'gone') { return $true }
    $holder = $found.Id
    if ([int]$holder -eq $PID) { return $true }
    if ($found.State -eq 'unknown') {
        [Console]::Error.WriteLine("not stopping pid $holder, which the lock names: the lock does not record when its holder started, so this may be another program")
        return $false
    }
    # The holder is stopped through this object, which keeps the process open
    # once its start time is read, so its ID cannot pass to another process
    # before it is stopped. Checked again: it may have ended since the read above.
    try {
        $proc = Get-Process -Id ([int]$holder) -ErrorAction Stop
        $started = $proc.StartTime
    } catch {
        return $true
    }
    if ([string]$started.ToUniversalTime().Ticks -cne $found.Start) { return $true }
    [Console]::Error.WriteLine("stopping the Labyrinth run (pid $holder) that holds the lock")
    foreach ($id in @(Get-LabDescendantId -ParentId ([int]$holder) -Since $started)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    try { $proc.Kill() } catch { Write-Verbose "holder not stopped: $($_.Exception.Message)" }
    return $proc.WaitForExit($WaitSeconds * 1000)
}

# Exit-LabLock: release the run lock if this process holds it.
function Exit-LabLock {
    $lock = Join-Path $env:LAB_STATE_DIR 'lock'
    $pidFile = Join-Path $lock 'pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    if (([IO.File]::ReadAllText($pidFile)).Trim() -notmatch "^$PID( \d+)?$") { return }
    Clear-LabLockFolder -Path $lock
}

# Clear-LabLockFolder -Path LOCK: delete the lock folder: its pid file, then
# the folder, which must then be empty. Never recursive: in PowerShell 5.1,
# Remove-Item -Recurse follows a junction planted in the folder and deletes
# what it points to.
function Clear-LabLockFolder {
    param([Parameter(Mandatory)] [string] $Path)
    $pidFile = Join-Path $Path 'pid'
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) { [IO.File]::Delete($pidFile) }
    [IO.Directory]::Delete($Path, $false)
}
