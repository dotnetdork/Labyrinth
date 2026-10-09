#Requires -Version 5.1
# core/safety/Safety.ps1: the safety gates and run lock (design 01,
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
# change the same host at once. A lock whose holder is gone is taken over.
# Returns $false if the lock is still held after N seconds.
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
            $holder = ''
            if (Test-Path -LiteralPath $pidFile) { $holder = ([IO.File]::ReadAllText($pidFile)).Trim() }
            if ($holder -match '^\d+$' -and -not (Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)) {
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
    [IO.File]::WriteAllText($pidFile, "$PID`n")
    return $true
}

# Get-LabDescendantId PID: the process IDs below PID, children first.
function Get-LabDescendantId {
    param([int] $ParentId)
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue)) {
        Get-LabDescendantId -ParentId ([int]$p.ProcessId)
        [int]$p.ProcessId
    }
}

# Close-LabLockHolder [-WaitSeconds N]: stop the live run that holds the lock
# and the entry points it started, waiting up to N seconds for it to end.
# The revert timer's rollback uses it, so it never undoes a run while that
# run is still changing the host. Returns $false if the holder still lives.
function Close-LabLockHolder {
    param([int] $WaitSeconds = 30)
    $pidFile = Join-Path (Join-Path $env:LAB_STATE_DIR 'lock') 'pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $true }
    $holder = ([IO.File]::ReadAllText($pidFile)).Trim()
    if ($holder -notmatch '^\d+$' -or [int]$holder -eq $PID) { return $true }
    if (-not (Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)) { return $true }
    [Console]::Error.WriteLine("stopping the Labyrinth run (pid $holder) that holds the lock")
    $ids = @(Get-LabDescendantId -ParentId ([int]$holder)) + @([int]$holder)
    foreach ($id in $ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    for ($n = 0; $n -lt $WaitSeconds; $n++) {
        if (-not (Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Exit-LabLock: release the run lock if this process holds it.
function Exit-LabLock {
    $lock = Join-Path $env:LAB_STATE_DIR 'lock'
    $pidFile = Join-Path $lock 'pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    if (([IO.File]::ReadAllText($pidFile)).Trim() -ne "$PID") { return }
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
