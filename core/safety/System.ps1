#Requires -Version 5.1
# core/safety/System.ps1: the Windows side of the safety code: the
# administrator check and the dead-man revert timer (design 03, section 8).
# Dot-sourced through core/Lab.ps1.
#
# The timer of a run is a one-time scheduled task \Labyrinth\lab-revert-<run>-<n>
# that runs as SYSTEM. Each re-arm registers a new one, with a new <n>, and
# only then removes the last, so a failed re-arm leaves the earlier timer
# armed. The armed timer's name is kept in $env:LAB_STATE_DIR\runs\<run>\timer.
#
# The warning that logged-in sessions get shortly before the undo is a second
# one-time task, \Labyrinth\lab-warn-<run>-<n>, armed and removed with the
# timer; its name is kept in runs\<run>\warn. It is best effort: it never
# blocks the timer.

function Test-LabAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LabRunDir {
    param([Parameter(Mandatory)] [string] $RunId)
    return Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $RunId
}

# Get-LabTrustedSid: the accounts that may own and use the data root:
# Administrators, SYSTEM and the account running Labyrinth.
function Get-LabTrustedSid {
    return @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
}

# Protect-LabDataRoot -Path ROOT: make the data root private to the trusted
# accounts, as umask 077 does on Linux. Under C:\ProgramData every user may
# create files, so without this any account on the host could read backups
# or plant a break-glass record, profile or lock for an administrator to
# trust. Throws if ROOT, or anything in it, is owned by another account:
# that item was planted, and a person must check it.
function Protect-LabDataRoot {
    param([Parameter(Mandatory)] [string] $Path)
    $trusted = @(Get-LabTrustedSid)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $trusted) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        # Created with its access list, so nobody can slip a file in first.
        [void][IO.Directory]::CreateDirectory($Path, $acl)
        return
    }
    $root = Get-Item -LiteralPath $Path -Force
    @($root) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force) | ForEach-Object {
        $owner = $_.GetAccessControl('Owner').GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $owner) {
            throw "data root: $($_.FullName) is owned by $owner, not by an administrator; check it and remove it by hand"
        }
    }
    $root.SetAccessControl($acl)
}

# Get-LabConsoleSession -Account NAME: the ID of NAME's session at this
# host's console (not a remote desktop session), $null if there is none,
# or 'unknown' if this host cannot tell (no query user). This supports the
# operator's break-glass answer; it does not prove the password works.
function Get-LabConsoleSession {
    param([Parameter(Mandatory)] [string] $Account)
    $quser = Join-Path $env:SystemRoot 'System32\quser.exe'
    if (-not (Test-Path -LiteralPath $quser)) { return 'unknown' }
    $short = ($Account -split '\\')[-1]
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # It exits non-zero, saying so on standard error, when no one is logged in.
        $lines = @(& $quser 2> $null | ForEach-Object { "$_" })
    } catch {
        return 'unknown'
    } finally {
        $ErrorActionPreference = $saved
    }
    foreach ($l in @($lines | Select-Object -Skip 1)) {
        $f = @($l.TrimStart(' ', '>') -split '\s+')
        if ($f.Count -ge 3 -and $f[0] -ieq $short -and $f[1] -ieq 'console') { return $f[2] }
    }
    return $null
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

# ConvertTo-LabCommandLineArgument VALUE: VALUE quoted for a Windows command
# line. Backslashes before the closing quote are doubled, so a path such as
# C:\Labyrinth\ keeps its meaning instead of escaping the quote.
function ConvertTo-LabCommandLineArgument {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)
    if ($Value.Contains('"')) { throw "argument holds a double quote: $Value" }
    return '"' + ($Value -replace '(\\+)$', '$1$1') + '"'
}

# Register-LabRevertTimer -Seconds N -RunId RUN -Execute EXE -Argument ARGS:
# (re)arm the run's revert timer to run EXE ARGS after N seconds, unless cancelled.
function Register-LabRevertTimer {
    param(
        [Parameter(Mandatory)] [int] $Seconds,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $Execute,
        [Parameter(Mandatory)] [string] $Argument
    )
    $dir = Get-LabRunDir $RunId
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $countFile = Join-Path $dir 'timer-count'
    $timerFile = Join-Path $dir 'timer'
    $n = 1
    if (Test-Path -LiteralPath $countFile) { $n = [int]([IO.File]::ReadAllText($countFile).Trim()) + 1 }
    $old = ''
    if (Test-Path -LiteralPath $timerFile) { $old = [IO.File]::ReadAllText($timerFile).Trim() }
    $name = "lab-revert-$RunId-$n"
    $at = (Get-Date).AddSeconds($Seconds)
    $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
    $trigger = New-ScheduledTaskTrigger -Once -At $at
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    [IO.File]::WriteAllText($countFile, "$n`n")
    [IO.File]::WriteAllText($timerFile, "$name`n")
    Save-LabRevertTimerDue -RunId $RunId -At $at
    # Only now is the earlier timer removed; it may already have run.
    if ($old -ne '') {
        Unregister-ScheduledTask -TaskName $old -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# Unregister-LabRevertTimer -RunId RUN: remove the run's revert timer, if one
# is armed. Throws, keeping the state files, if the task is still there
# afterwards, because the run would still be rolled back.
function Unregister-LabRevertTimer {
    param([Parameter(Mandatory)] [string] $RunId)
    $dir = Get-LabRunDir $RunId
    $f = Join-Path $dir 'timer'
    if (-not (Test-Path -LiteralPath $f)) { return }
    $name = [IO.File]::ReadAllText($f).Trim()
    # The task may already have run or been removed by hand.
    Unregister-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue) {
        throw "the revert timer $name could not be removed"
    }
    Remove-Item -LiteralPath $f -Force
    Remove-Item -LiteralPath (Join-Path $dir 'timer-due') -Force -ErrorAction SilentlyContinue
    # The warning goes with it. Best effort: one left behind sees that the run has
    # no timer and sends nothing.
    try { [void](Unregister-LabRevertWarning -RunId $RunId) } catch { Write-Verbose "warning not removed: $($_.Exception.Message)" }
}

# Get-LabWarnLead -Seconds N: how many seconds before the undo the warning is
# sent for a revert timer of N seconds: 60, or half the time when the timer is
# shorter than two minutes (docs\Conventions.md, section 3.1). 0 means the
# timer is too short to warn.
function Get-LabWarnLead {
    param([Parameter(Mandatory)] [int] $Seconds)
    if ($Seconds -ge 120) { return 60 }
    return [int][Math]::Floor($Seconds / 2)
}

# Register-LabRevertWarning -Seconds N -RunId RUN -Execute EXE -Argument ARGS:
# (re)arm the run's warning, a one-time scheduled task
# \Labyrinth\lab-warn-<run>-<n> that runs EXE ARGS Get-LabWarnLead seconds
# before its revert timer, which is N seconds from now, fires. Called right
# after Register-LabRevertTimer, whose count it shares. As for the timer, the
# new task is registered before the earlier one is removed. Throws on failure
# after removing the earlier warning too, as it would name the wrong time; the
# caller goes on, because the warning is best effort.
function Register-LabRevertWarning {
    param(
        [Parameter(Mandatory)] [int] $Seconds,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [string] $Execute,
        [Parameter(Mandatory)] [string] $Argument
    )
    $dir = Get-LabRunDir $RunId
    $warnFile = Join-Path $dir 'warn'
    $lead = Get-LabWarnLead -Seconds $Seconds
    if ($lead -lt 1) {
        [void](Unregister-LabRevertWarning -RunId $RunId)
        return
    }
    $old = ''
    if (Test-Path -LiteralPath $warnFile) { $old = [IO.File]::ReadAllText($warnFile).Trim() }
    $name = ''
    try {
        $n = [int]([IO.File]::ReadAllText((Join-Path $dir 'timer-count')).Trim())
        $name = "lab-warn-$RunId-$n"
        $at = (Get-Date).AddSeconds($Seconds - $lead)
        $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
        $trigger = New-ScheduledTaskTrigger -Once -At $at
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        [IO.File]::WriteAllText($warnFile, "$name`n")
    } catch {
        $failure = $_
        if ($name -ne '') {
            Unregister-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
        }
        [void](Unregister-LabRevertWarning -RunId $RunId)
        throw $failure
    }
    if ($old -ne '' -and $old -cne $name) {
        Unregister-ScheduledTask -TaskName $old -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# Unregister-LabRevertWarning -RunId RUN: remove the run's warning, if one is
# armed. Returns $false, keeping the state file, if the task is still there
# afterwards; the caller goes on, because a warning left behind sees that the
# run has no timer and sends nothing.
function Unregister-LabRevertWarning {
    param([Parameter(Mandatory)] [string] $RunId)
    $f = Join-Path (Get-LabRunDir $RunId) 'warn'
    if (-not (Test-Path -LiteralPath $f)) { return $true }
    $name = [IO.File]::ReadAllText($f).Trim()
    if ($name -cmatch '^lab-warn-[A-Za-z0-9-]+$') {
        Unregister-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
        if (Get-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue) { return $false }
    }
    Remove-Item -LiteralPath $f -Force
    return $true
}

# Save-LabRevertTimerDue -RunId RUN -At TIME: record when the run's revert
# timer fires, in UTC (YYYY-MM-DDTHH:MM:SSZ). Advisory: a failure is ignored.
function Save-LabRevertTimerDue {
    param([Parameter(Mandatory)] [string] $RunId, [Parameter(Mandatory)] [datetime] $At)
    try {
        $due = $At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::WriteAllText((Join-Path (Get-LabRunDir $RunId) 'timer-due'), "$due`n")
    } catch {
        Write-Verbose "timer-due not written: $($_.Exception.Message)"
    }
}

# Get-LabRevertTimerDue -RunId RUN: when the run's revert timer fires, as
# written by Save-LabRevertTimerDue, or '' if unknown.
function Get-LabRevertTimerDue {
    param([Parameter(Mandatory)] [string] $RunId)
    $f = Join-Path (Get-LabRunDir $RunId) 'timer-due'
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
    $due = ([IO.File]::ReadAllText($f)).Trim()
    if ($due -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { return '' }
    return $due
}

# Get-LabRevertTimerLeft -RunId RUN: the whole seconds until the run's revert
# timer fires, 0 when that time has passed, or -1 when the time is unknown.
# -Extend adds one timer length to this and re-arms (Register-LabRevertTimer)
# for the total.
function Get-LabRevertTimerLeft {
    param([Parameter(Mandatory)] [string] $RunId)
    $due = Get-LabRevertTimerDue -RunId $RunId
    if ($due -eq '') { return -1 }
    $when = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParseExact($due, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $when)) { return -1 }
    $left = [int][Math]::Floor(($when - [DateTime]::UtcNow).TotalSeconds)
    if ($left -lt 0) { return 0 }
    return $left
}

# Test-LabRevertTimer -RunId RUN: is a revert timer armed for the run?
function Test-LabRevertTimer {
    param([Parameter(Mandatory)] [string] $RunId)
    return (Test-Path -LiteralPath (Join-Path (Get-LabRunDir $RunId) 'timer'))
}

# Test-LabTimerReady: '' when a revert timer can be armed, else the reason it
# cannot. Read-only: the Task Scheduler service runs and the scheduling
# commands exist. No test timer is armed (-Doctor).
function Test-LabTimerReady {
    $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return 'the Task Scheduler service is missing' }
    if ($svc.Status -ne 'Running') { return 'the Task Scheduler service is not running' }
    if ($null -eq (Get-Command -Name 'Register-ScheduledTask' -ErrorAction SilentlyContinue)) {
        return 'the scheduling commands are missing'
    }
    return ''
}

# Get-LabClockSync: the time-sync service that is running ('Windows Time'),
# '' when none is, or 'unknown' when that cannot be told. Never asks the
# network (-Doctor).
function Get-LabClockSync {
    $svc = Get-Service -Name 'w32time' -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return '' }
    if ($svc.Status -eq 'Running') { return 'Windows Time' }
    return ''
}

# Send-LabNotice -Message TEXT: show TEXT in every session logged in on this
# host, so the team learns that a run was rolled back even when no one is
# watching the revert timer. Best effort: returns $false when msg.exe is
# missing or fails, and the caller goes on.
function Send-LabNotice {
    param([Parameter(Mandatory)] [string] $Message)
    $exe = Join-Path $env:SystemRoot 'System32\msg.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    try {
        $null = & $exe '*' '/TIME:900' $Message 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
