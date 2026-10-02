#Requires -Version 5.1
# core/safety/System.ps1: the Windows side of the safety code: the
# administrator check and the dead-man revert timer (design 01, section 8).
# Dot-sourced through core/Lab.ps1.
#
# The timer of a run is a one-time scheduled task \Labyrinth\lab-revert-<run>-<n>
# that runs as SYSTEM. Each re-arm registers a new one, with a new <n>, after
# removing the last, and its name is kept in $env:LAB_STATE_DIR\runs\<run>\timer.

function Test-LabAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LabRunDir {
    param([Parameter(Mandatory)] [string] $RunId)
    return Join-Path (Join-Path $env:LAB_STATE_DIR 'runs') $RunId
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
    Unregister-LabRevertTimer -RunId $RunId
    $countFile = Join-Path $dir 'timer-count'
    $n = 1
    if (Test-Path -LiteralPath $countFile) { $n = [int]([IO.File]::ReadAllText($countFile).Trim()) + 1 }
    $name = "lab-revert-$RunId-$n"
    $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds($Seconds))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    [IO.File]::WriteAllText($countFile, "$n`n")
    [IO.File]::WriteAllText((Join-Path $dir 'timer'), "$name`n")
}

# Unregister-LabRevertTimer -RunId RUN: remove the run's revert timer, if one is armed.
function Unregister-LabRevertTimer {
    param([Parameter(Mandatory)] [string] $RunId)
    $f = Join-Path (Get-LabRunDir $RunId) 'timer'
    if (-not (Test-Path -LiteralPath $f)) { return }
    $name = [IO.File]::ReadAllText($f).Trim()
    # The task may already have run or been removed by hand.
    Unregister-ScheduledTask -TaskName $name -TaskPath '\Labyrinth\' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $f -Force
}

# Test-LabRevertTimer -RunId RUN: is a revert timer armed for the run?
function Test-LabRevertTimer {
    param([Parameter(Mandatory)] [string] $RunId)
    return (Test-Path -LiteralPath (Join-Path (Get-LabRunDir $RunId) 'timer'))
}
