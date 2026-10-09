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
                Remove-Item -LiteralPath $lock -Recurse -Force
                continue
            }
            if ($waited -ge $WaitSeconds) {
                [Console]::Error.WriteLine("another Labyrinth run (pid $holder) holds $lock")
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
    Remove-Item -LiteralPath $lock -Recurse -Force
}

# Get-LabRandomPassword [-Length N]: a random password from
# RandomNumberGenerator, with at least one upper-case letter, lower-case
# letter and digit, without characters that are easy to misread. Show it
# once to the operator; never write it to a file or a log (design 01, section 8).
function Get-LabRandomPassword {
    param([ValidateRange(12, 128)] [int] $Length = 20)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $n = $alphabet.Length
    # The largest multiple of the alphabet size up to 256: bytes from it up
    # are rejected, so every character is equally likely.
    $limit = 256 - (256 % $n)
    $buf = New-Object byte[] 64
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($true) {
            $sb = New-Object Text.StringBuilder
            while ($sb.Length -lt $Length) {
                $rng.GetBytes($buf)
                foreach ($b in $buf) {
                    if ($b -ge $limit) { continue }
                    [void]$sb.Append($alphabet[$b % $n])
                    if ($sb.Length -ge $Length) { break }
                }
            }
            $pw = $sb.ToString()
            if ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '[0-9]') { return $pw }
        }
    } finally {
        $rng.Dispose()
    }
}
