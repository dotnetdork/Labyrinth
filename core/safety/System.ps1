#Requires -Version 5.1
# core/safety/System.ps1: the Windows side of the safety code: the
# administrator check and the dead-man revert timer (design 01, section 8).
# Dot-sourced through core/Lab.ps1.
#
# The timer of a run is a one-time scheduled task \Labyrinth\lab-revert-<run>-<n>
# that runs as SYSTEM. Each re-arm registers a new one, with a new <n>, and
# only then removes the last, so a failed re-arm leaves the earlier timer
# armed. The armed timer's name is kept in $env:LAB_STATE_DIR\runs\<run>\timer.

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

# Test-LabRevertTimer -RunId RUN: is a revert timer armed for the run?
function Test-LabRevertTimer {
    param([Parameter(Mandatory)] [string] $RunId)
    return (Test-Path -LiteralPath (Join-Path (Get-LabRunDir $RunId) 'timer'))
}
