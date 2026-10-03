#Requires -Version 5.1
# Shared setup for the PowerShell runner tests, dot-sourced in BeforeAll.
# Each test gets a throwaway Labyrinth tree with the core, the fixture
# modules from tests\fixtures\modules and the test doubles from
# tests\fixtures\Doubles.ps1, plus its own data root and run-time
# configuration directory. Nothing outside TestDrive is used.

$script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:HostExe = (Get-Process -Id $PID).Path
$script:ThisHost = ($env:COMPUTERNAME -split '\.')[0]

# Initialize-TestLab: a new tree; returns an object with Lab, Root and Etc.
function Initialize-TestLab {
    $base = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
    $t = [pscustomobject]@{
        Lab  = Join-Path $base 'lab'
        Root = Join-Path $base 'root'
        Etc  = Join-Path $base 'etc'
    }
    $modules = Join-Path $t.Lab 'phases\observe\modules'
    New-Item -ItemType Directory -Path $modules, (Join-Path $t.Lab 'profiles'), $t.Etc -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:Repo 'labyrinth.ps1') -Destination $t.Lab
    Copy-Item -LiteralPath (Join-Path $script:Repo 'core') -Destination $t.Lab -Recurse
    Get-ChildItem -LiteralPath (Join-Path $script:Repo 'tests\fixtures\modules') -Directory |
        Copy-Item -Destination $modules -Recurse
    $doubles = [IO.File]::ReadAllText((Join-Path $script:Repo 'tests\fixtures\Doubles.ps1'))
    [IO.File]::AppendAllText((Join-Path $t.Lab 'core\Lab.ps1'), "`n$doubles")
    Write-TestConfig $t 'protected-accounts' @('labadmin breakglass', 'scoring1 scoring')
    return $t
}

# Write-TestConfig T NAME LINES: write a run-time configuration file.
function Write-TestConfig {
    param($T, [string] $Name, [AllowEmptyCollection()] [string[]] $Lines)
    [IO.File]::WriteAllText((Join-Path $T.Etc $Name), (($Lines | ForEach-Object { "$_`n" }) -join ''))
}

function Write-TestProfile {
    param($T, [string[]] $Ids)
    Set-Content -LiteralPath (Join-Path $T.Lab 'profiles\test.profile') -Value $Ids -Encoding Ascii
}

# Write-TestHost T GROUP: list this host in the hosts file, with the test profile.
function Write-TestHost {
    param($T, [string] $Group)
    Write-TestConfig $T 'hosts' @("$script:ThisHost $Group test windows")
}

# Invoke-TestLab T ARGS [-Answers LINES]: run labyrinth.ps1 in its own
# process, as an operator would, typing LINES at its prompts.
function Invoke-TestLab {
    param($T, [string[]] $Arguments, [string[]] $Answers = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $Answers | & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $T.Lab 'labyrinth.ps1') @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    return [pscustomobject]@{
        Code   = $code
        Output = (@($out) | ForEach-Object { "$_" }) -join "`n"
    }
}

# Invoke-TestLabCapture T ARGS: run labyrinth.ps1 in its own process with
# no input, keeping stdout and stderr apart. Returns Code, Out and Err.
function Invoke-TestLabCapture {
    param($T, [AllowEmptyCollection()] [string[]] $Arguments = @())
    $quoted = @((Join-Path $T.Lab 'labyrinth.ps1')) + $Arguments | ForEach-Object {
        if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return [pscustomobject]@{
        Code = $p.ExitCode
        Out  = $out.Result.TrimEnd()
        Err  = $err.Result.TrimEnd()
    }
}

function Invoke-TestPlan {
    param($T, [string[]] $Extra = @())
    Invoke-TestLab $T (@('observe', '-Profile', 'test', '-Root', $T.Root, '-Config', $T.Etc) + $Extra)
}

function Invoke-TestApply {
    param($T, [string[]] $Answers = @(), [string[]] $Extra = @())
    Invoke-TestLab $T (@('observe', '-Apply', '-Root', $T.Root, '-Config', $T.Etc) + $Extra) -Answers $Answers
}

# Invoke-TestRunCommand T COMMAND RUN: keep or rollback a run.
function Invoke-TestRunCommand {
    param($T, [string] $Command, [string] $RunId)
    Invoke-TestLab $T @($Command, $RunId, '-Root', $T.Root, '-Config', $T.Etc)
}

# Get-TestRunId OUTPUT: the run id in a run's output.
function Get-TestRunId {
    param([string] $Output)
    if ($Output -match 'run (\d{8}T\d{6}Z-[0-9a-f]{4})') { return $Matches[1] }
    return ''
}

function Get-TestManifest {
    param($T, [string] $RunId)
    return [IO.File]::ReadAllText((Join-Path $T.Root "state\runs\$RunId\manifest.jsonl"))
}
