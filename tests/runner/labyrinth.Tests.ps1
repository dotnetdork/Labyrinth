#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 in plan mode (design 00, sections 4 and 5).
# Each test builds a throwaway Labyrinth tree holding the fixture modules
# from tests/fixtures/modules, so nothing outside TestDrive is used.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:HostExe = (Get-Process -Id $PID).Path

    function Initialize-TestLab {
        $lab = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $modules = Join-Path $lab 'phases\observe\modules'
        New-Item -ItemType Directory -Path $modules, (Join-Path $lab 'profiles') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'labyrinth.ps1') -Destination $lab
        Get-ChildItem -LiteralPath (Join-Path $script:Repo 'tests\fixtures\modules') -Directory |
            Copy-Item -Destination $modules -Recurse
        return $lab
    }

    function Write-TestProfile {
        param([string] $Lab, [string[]] $Ids)
        Set-Content -LiteralPath (Join-Path $Lab 'profiles\test.profile') -Value $Ids -Encoding Ascii
    }

    # Runs labyrinth.ps1 in its own process, as an operator would.
    function Invoke-TestLab {
        param([string] $Lab, [string[]] $Arguments)
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File (Join-Path $Lab 'labyrinth.ps1') @Arguments 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        return [pscustomobject]@{
            Code   = $code
            Output = (@($out) | ForEach-Object { "$_" }) -join "`n"
        }
    }

    function Invoke-TestPlan {
        param([string] $Lab, [string[]] $Extra = @())
        $root = Join-Path $TestDrive 'root'
        Invoke-TestLab $Lab (@('observe', '-Profile', 'test', '-Root', $root) + $Extra)
    }
}

Describe 'labyrinth.ps1 plan mode' {
    BeforeEach {
        $lab = Initialize-TestLab
        $root = Join-Path $TestDrive 'root'
    }

    It 'the no-op sample module: check says a change is needed, plan runs, exit 10' {
        Write-TestProfile $lab 'observe.sample'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 10
        $r.Output | Should -Match 'sample: would change nothing'
    }

    It 'plan mode never runs apply' {
        Write-TestProfile $lab 'observe.sample'
        Invoke-TestPlan $lab | Out-Null
        Join-Path $lab 'APPLIED' | Should -Not -Exist
    }

    It 'plan mode creates nothing under the data root' {
        Write-TestProfile $lab @('observe.sample', 'observe.envdump')
        Invoke-TestPlan $lab | Out-Null
        $root | Should -Not -Exist
    }

    It 'nothing to do exits 0' {
        Write-TestProfile $lab 'observe.clean'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 0
        $r.Output | Should -Match '\[observe\.clean\] check: nothing to do'
    }

    It 'a safety-gate block exits 20' {
        Write-TestProfile $lab 'observe.blocked'
        (Invoke-TestPlan $lab).Code | Should -Be 20
    }

    It 'an exit code outside the contract becomes 40' {
        Write-TestProfile $lab 'observe.crash'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'error \(exit 3\)'
    }

    It 'a change with no plan entry point is an error' {
        Write-TestProfile $lab 'observe.noplan'
        (Invoke-TestPlan $lab).Code | Should -Be 40
    }

    It 'a module with no Windows entry points is skipped' {
        Write-TestProfile $lab 'observe.linuxonly'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'skipped: no Windows entry points'
    }

    It 'entry points get the contract environment, in plan mode' {
        Write-TestProfile $lab 'observe.envdump'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape("LAB_ROOT=$lab"))
        $r.Output | Should -Match ([regex]::Escape("LAB_CONFIG_DIR=$(Join-Path $root 'etc')"))
        $r.Output | Should -Match ([regex]::Escape("LAB_STATE_DIR=$(Join-Path $root 'state')"))
        $r.Output | Should -Match ([regex]::Escape("LAB_LOG_DIR=$(Join-Path $root 'logs')"))
        $r.Output | Should -Match ([regex]::Escape("LAB_BACKUP_DIR=$(Join-Path $root 'backup')"))
        $r.Output | Should -Match 'LAB_MODULE_ID=observe\.envdump'
        $r.Output | Should -Match 'LAB_DRY_RUN=1'
        $r.Output | Should -Match 'LAB_RUN_ID=\d{8}T\d{6}Z-[0-9a-f]{4}'
    }

    It 'an unknown module.yml key is rejected' {
        Write-TestProfile $lab 'observe.badyml'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'unknown key color'
    }

    It 'module.yml outside the flat subset is rejected: <Platforms> <Extra>' -TestCases @(
        @{ Platforms = '[]'; Extra = '' }
        @{ Platforms = '[ ]'; Extra = '' }
        @{ Platforms = 'ubuntu'; Extra = '' }
        @{ Platforms = '[ubuntu'; Extra = '' }
        @{ Platforms = '[ubuntu, bogus]'; Extra = '' }
        @{ Platforms = '[ubuntu]'; Extra = 'requires: &anchor' }
        @{ Platforms = '[ubuntu]'; Extra = 'outputs: |' }
        @{ Platforms = '[ubuntu]'; Extra = '  nested: true' }
        @{ Platforms = '[ubuntu]'; Extra = 'risk: reversible' }
    ) {
        param($Platforms, $Extra)
        $dir = Join-Path $lab 'phases\observe\modules\clean'
        $yml = @('id: observe.clean', 'phase: observe', 'priority: P2', "platforms: $Platforms",
            'risk: read-only', 'touches_scored: false', $Extra)
        Set-Content -LiteralPath (Join-Path $dir 'module.yml') -Value $yml -Encoding Ascii
        Write-TestProfile $lab 'observe.clean'
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'invalid module\.yml'
    }

    It 'a well-formed module.yml with spaces in its lists is accepted' {
        $dir = Join-Path $lab 'phases\observe\modules\clean'
        $yml = @('# comment', '', 'id: observe.clean', 'phase: observe', 'priority: P2',
            'platforms: [ ubuntu , windows ]', 'risk: read-only', 'touches_scored: false', 'requires: []')
        Set-Content -LiteralPath (Join-Path $dir 'module.yml') -Value $yml -Encoding Ascii
        Write-TestProfile $lab 'observe.clean'
        (Invoke-TestPlan $lab).Code | Should -Be 0
    }

    It 'a module.yml id that does not match its folder is rejected' {
        Write-TestProfile $lab 'observe.badid'
        (Invoke-TestPlan $lab).Code | Should -Be 40
    }

    It 'a module in the profile that does not exist is an error' {
        Write-TestProfile $lab 'observe.missing'
        (Invoke-TestPlan $lab).Code | Should -Be 40
    }

    It 'only the requested phase runs, in profile order, and the highest code wins' {
        Write-TestProfile $lab @('lockout.other', 'observe.clean', 'observe.sample', 'observe.blocked')
        $r = Invoke-TestPlan $lab
        $r.Code | Should -Be 20
        $r.Output | Should -Not -Match 'lockout\.other'
        $r.Output.IndexOf('observe.clean') | Should -BeLessThan $r.Output.IndexOf('observe.sample')
    }

    It 'a run-time profile replaces the shipped one' {
        Write-TestProfile $lab 'observe.sample'
        $etc = Join-Path $TestDrive 'etc'
        New-Item -ItemType Directory -Path (Join-Path $etc 'profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $etc 'profiles\test.profile') -Value 'observe.clean' -Encoding Ascii
        $r = Invoke-TestPlan $lab @('-Config', $etc)
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'observe\.sample'
    }

    It 'a profile line that is not a module id is rejected' {
        Write-TestProfile $lab 'not a module'
        (Invoke-TestPlan $lab).Code | Should -Be 40
    }

    It '-Apply is refused in this build' {
        Write-TestProfile $lab 'observe.sample'
        (Invoke-TestPlan $lab @('-Apply')).Code | Should -Be 40
        Join-Path $lab 'APPLIED' | Should -Not -Exist
    }

    It 'argument errors exit 40' {
        Write-TestProfile $lab 'observe.sample'
        (Invoke-TestLab $lab @('observe')).Code | Should -Be 40
        (Invoke-TestLab $lab @('nope', '-Profile', 'test')).Code | Should -Be 40
        (Invoke-TestLab $lab @('observe', '-Profile', 'a;b')).Code | Should -Be 40
        (Invoke-TestLab $lab @('observe', '-Profile', 'test', '-Root', 'relative')).Code | Should -Be 40
        (Invoke-TestLab $lab @('observe', '-Profile', 'nosuch', '-Root', $root)).Code | Should -Be 40
        (Invoke-TestLab $lab @('observe', '-Profile', 'test', '-Bogus')).Code | Should -Be 40
    }

    It '-Version and -Help exit 0' {
        (Invoke-TestLab $lab @('-Version')).Code | Should -Be 0
        (Invoke-TestLab $lab @('-Help')).Code | Should -Be 0
    }
}
