#Requires -Version 5.1
# ---- Test doubles, appended to core\Lab.ps1 in the throwaway test tree only ----
# They replace the host-specific parts of the core, so runner tests need no
# administrator rights, no scheduled tasks and no network:
#   - the administrator check passes unless $env:LAB_ROOT\NOT_ADMIN exists;
#   - the revert timer is recorded in $env:LAB_ROOT\timer.log instead of registered;
#   - a probe fails if its host is listed as "<host> fail" in
#     $env:LAB_ROOT\probe-state, and passes otherwise.

function Test-LabAdmin { return -not (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'NOT_ADMIN')) }

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
