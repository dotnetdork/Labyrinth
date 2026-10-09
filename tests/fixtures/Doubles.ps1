#Requires -Version 5.1
# ---- Test doubles, appended to core\Lab.ps1 in the throwaway test tree only ----
# They replace the host-specific parts of the core, so runner tests need no
# administrator rights, no scheduled tasks and no network:
#   - the administrator check passes unless $env:LAB_ROOT\NOT_ADMIN exists;
#   - the ownership check passes unless $env:LAB_ROOT\UNTRUSTED exists;
#   - the revert timer is recorded in $env:LAB_ROOT\timer.log instead of registered;
#   - a probe fails if its host is listed as "<host> fail" in
#     $env:LAB_ROOT\probe-state, and passes otherwise;
#   - the console is two files, $env:LAB_ROOT\tty.out and tty.in (below).

function Test-LabAdmin { return -not (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'NOT_ADMIN')) }

function Find-LabUntrustedItem {
    param([AllowEmptyString()] [string[]] $Path)
    $null = $Path
    if (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'UNTRUSTED')) { return $env:LAB_ROOT }
    return $null
}

function Register-LabRevertTimer {
    param([int] $Seconds, [string] $RunId, [string] $Execute, [string] $Argument)
    $dir = Get-LabRunDir $RunId
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'timer'), "$Execute $Argument`n")
    Save-LabRevertTimerDue -RunId $RunId -At ((Get-Date).AddSeconds($Seconds))
    Add-Content -LiteralPath (Join-Path $env:LAB_ROOT 'timer.log') -Value "arm $RunId $Seconds" -Encoding Ascii
}

function Unregister-LabRevertTimer {
    param([string] $RunId)
    $f = Join-Path (Get-LabRunDir $RunId) 'timer'
    if (-not (Test-Path -LiteralPath $f)) { return }
    Remove-Item -LiteralPath $f -Force
    Remove-Item -LiteralPath (Join-Path (Get-LabRunDir $RunId) 'timer-due') -Force -ErrorAction SilentlyContinue
    Add-Content -LiteralPath (Join-Path $env:LAB_ROOT 'timer.log') -Value "cancel $RunId" -Encoding Ascii
}

function Invoke-LabProbe {
    param([string] $Proto, [string] $Target, [int] $Port, [string] $Expect, [int] $Timeout = 5)
    $null = $Proto, $Port, $Expect, $Timeout
    $state = Join-Path $env:LAB_ROOT 'probe-state'
    if ((Test-Path -LiteralPath $state) -and (@(Get-Content -LiteralPath $state) -contains "$Target fail")) { return 'fail fake probe' }
    return 'pass fake probe'
}

# The console: writes go to $env:LAB_ROOT\tty.out and each read takes the
# next line of $env:LAB_ROOT\tty.in, $null when there is none; there is no
# console at all if $env:LAB_ROOT\NO_TTY exists.
function Test-LabTerminal { return -not (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'NO_TTY')) }

function Write-LabTerminal {
    param([string] $Text)
    [IO.File]::AppendAllText((Join-Path $env:LAB_ROOT 'tty.out'), $Text)
}

function Read-LabTerminal {
    $posFile = Join-Path $env:LAB_ROOT 'tty.pos'
    $pos = 0
    if (Test-Path -LiteralPath $posFile) { $pos = [int]([IO.File]::ReadAllText($posFile).Trim()) }
    $pos++
    [IO.File]::WriteAllText($posFile, "$pos")
    $in = Join-Path $env:LAB_ROOT 'tty.in'
    if (-not (Test-Path -LiteralPath $in)) { return $null }
    $lines = @(Get-Content -LiteralPath $in)
    if ($lines.Count -lt $pos) { return $null }
    return $lines[$pos - 1]
}

function Get-LabTerminalRow { return 0 }

function Clear-LabTerminal {
    param([int] $Row)
    [IO.File]::AppendAllText((Join-Path $env:LAB_ROOT 'tty.out'), "[cleared from row $Row]")
}
