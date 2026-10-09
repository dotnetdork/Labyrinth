#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 in plan mode (design 00, sections 4 and 5).
# Each test builds a throwaway Labyrinth tree (see LabTestHelper.ps1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
}

Describe 'labyrinth.ps1 plan mode' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $root = $t.Root
    }

    It 'the no-op sample module: check says a change is needed, plan runs, exit 10' {
        Write-TestProfile $t 'observe.sample'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $r.Output | Should -Match 'sample: would change nothing'
    }

    It 'plan mode never runs apply' {
        Write-TestProfile $t 'observe.toggle'
        (Invoke-TestPlan $t).Code | Should -Be 10
        $conf = Join-Path $lab 'toggle.conf'
        if (Test-Path -LiteralPath $conf) { (Get-Content -LiteralPath $conf) -ccontains 'setting=on' | Should -BeFalse }
    }

    It 'plan mode creates nothing under the data root' {
        Write-TestProfile $t @('observe.sample', 'observe.envdump')
        Invoke-TestPlan $t | Out-Null
        $root | Should -Not -Exist
    }

    It 'nothing to do exits 0' {
        Write-TestProfile $t 'observe.clean'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        (@($r.Output -split "`r?`n") -ccontains 'OK       Nothing-to-do sample (observe.clean)') | Should -BeTrue
    }

    It 'a safety-gate block exits 20' {
        Write-TestProfile $t 'observe.blocked'
        (Invoke-TestPlan $t).Code | Should -Be 20
    }

    It 'an exit code outside the contract becomes 40' {
        Write-TestProfile $t 'observe.crash'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'failed with exit code 3'
    }

    It 'a change with no plan entry point is an error' {
        Write-TestProfile $t 'observe.noplan'
        (Invoke-TestPlan $t).Code | Should -Be 40
    }

    It 'a module with no Windows entry points is skipped' {
        Write-TestProfile $t 'observe.linuxonly'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'skipped: no Windows entry points'
    }

    It 'entry points get the contract environment, in plan mode' {
        Write-TestProfile $t 'observe.envdump'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape("LAB_ROOT=$lab"))
        $r.Output | Should -Match ([regex]::Escape("LAB_CONFIG_DIR=$($t.Etc)"))
        $r.Output | Should -Match ([regex]::Escape("LAB_STATE_DIR=$(Join-Path $root 'state')"))
        $r.Output | Should -Match ([regex]::Escape("LAB_LOG_DIR=$(Join-Path $root 'logs')"))
        $r.Output | Should -Match ([regex]::Escape("LAB_BACKUP_DIR=$(Join-Path $root 'backup')"))
        $r.Output | Should -Match 'LAB_MODULE_ID=observe\.envdump'
        $r.Output | Should -Match 'LAB_DRY_RUN=1'
        $r.Output | Should -Match 'LAB_RUN_ID=\d{8}T\d{6}Z-[0-9a-f]{4}'
    }

    It 'an unknown module.yml key is rejected' {
        Write-TestProfile $t 'observe.badyml'
        $r = Invoke-TestPlan $t
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
        $yml = @('id: observe.clean', 'title: Clean', 'phase: observe', 'priority: P2', "platforms: $Platforms",
            'risk: read-only', 'touches_scored: false', $Extra)
        Set-Content -LiteralPath (Join-Path $dir 'module.yml') -Value $yml -Encoding Ascii
        Write-TestProfile $t 'observe.clean'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'invalid module\.yml'
    }

    It 'a well-formed module.yml with spaces in its lists is accepted' {
        $dir = Join-Path $lab 'phases\observe\modules\clean'
        $yml = @('# comment', '', 'id: observe.clean', 'title: Clean: no change', 'phase: observe', 'priority: P2',
            'platforms: [ ubuntu , windows ]', 'risk: read-only', 'touches_scored: false', 'requires: []')
        Set-Content -LiteralPath (Join-Path $dir 'module.yml') -Value $yml -Encoding Ascii
        Write-TestProfile $t 'observe.clean'
        (Invoke-TestPlan $t).Code | Should -Be 0
    }

    It 'a module.yml without a title, or with one over 40 characters, is rejected' {
        $file = Join-Path $lab 'phases\observe\modules\clean\module.yml'
        $orig = Get-Content -LiteralPath $file
        try {
            Write-TestProfile $t 'observe.clean'
            Set-Content -LiteralPath $file -Value @($orig | Where-Object { $_ -notlike 'title:*' }) -Encoding Ascii
            $r = Invoke-TestPlan $t
            $r.Code | Should -Be 40
            $r.Output | Should -Match 'missing key title'
            Set-Content -LiteralPath $file -Encoding Ascii -Value @($orig | ForEach-Object {
                    if ($_ -like 'title:*') { 'title: A title that runs on well past forty characters' } else { $_ } })
            $r = Invoke-TestPlan $t
            $r.Code | Should -Be 40
            $r.Output | Should -Match 'title is 47 characters; the most is 40'
        } finally {
            Set-Content -LiteralPath $file -Value $orig -Encoding Ascii
        }
    }

    It 'a module.yml id that does not match its folder is rejected' {
        Write-TestProfile $t 'observe.badid'
        (Invoke-TestPlan $t).Code | Should -Be 40
    }

    It 'a module in the profile that does not exist is an error' {
        Write-TestProfile $t 'observe.missing'
        (Invoke-TestPlan $t).Code | Should -Be 40
    }

    It 'a read-only or manual-only module that ships apply, rollback or cleanup is rejected' {
        $clean = Join-Path $lab 'phases\observe\modules\clean'
        foreach ($entry in @('apply', 'rollback', 'cleanup')) {
            $file = Join-Path $clean "$entry.ps1"
            Set-Content -LiteralPath $file -Value 'exit 0' -Encoding Ascii
            Write-TestProfile $t 'observe.clean'
            $r = Invoke-TestPlan $t
            $r.Code | Should -Be 40
            $r.Output | Should -Match "$entry\.ps1 is not allowed: a read-only module changes nothing"
            Remove-Item -LiteralPath $file
        }
        Set-Content -LiteralPath (Join-Path $lab 'phases\observe\modules\manual\apply.ps1') -Value 'exit 0' -Encoding Ascii
        Write-TestProfile $t 'observe.manual'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'apply.ps1 is not allowed: a manual-only module changes nothing'
    }

    It 'only the requested phase runs, in profile order, and the highest code wins' {
        Write-TestProfile $t @('lockout.other', 'observe.clean', 'observe.sample', 'observe.blocked')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 20
        $r.Output | Should -Not -Match 'lockout\.other'
        $r.Output.IndexOf('observe.clean') | Should -BeLessThan $r.Output.IndexOf('observe.sample')
    }

    It 'a run-time profile replaces the shipped one' {
        Write-TestProfile $t 'observe.sample'
        New-Item -ItemType Directory -Path (Join-Path $t.Etc 'profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $t.Etc 'profiles\test.profile') -Value 'observe.clean' -Encoding Ascii
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'observe\.sample'
    }

    It 'a profile line that is not a module id is rejected' {
        Write-TestProfile $t 'not a module'
        (Invoke-TestPlan $t).Code | Should -Be 40
    }

    It 'plan mode refuses to run without the protected set' {
        Write-TestProfile $t 'observe.clean'
        Remove-Item -LiteralPath (Join-Path $t.Etc 'protected-accounts')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'protected set is not loaded'
        Write-TestConfig $t 'protected-accounts' @('# only a comment')
        (Invoke-TestPlan $t).Code | Should -Be 20
    }

    It 'a malformed protected set is an error' {
        Write-TestProfile $t 'observe.clean'
        Write-TestConfig $t 'protected-accounts' @('labadmin superuser')
        (Invoke-TestPlan $t).Code | Should -Be 40
    }

    It 'modules run by priority, then in profile order' {
        Write-TestProfile $t @('observe.sample', 'observe.clean')
        $yml = Join-Path $lab 'phases\observe\modules\clean\module.yml'
        Set-Content -LiteralPath $yml -Value ((Get-Content -LiteralPath $yml) -replace '^priority: P2', 'priority: P0') -Encoding Ascii
        $r = Invoke-TestPlan $t
        $r.Output.IndexOf('observe.clean') | Should -BeLessThan $r.Output.IndexOf('observe.sample')
    }

    It 'the profile comes from the hosts file when -Profile is not given' {
        Write-TestProfile $t 'observe.clean'
        Write-TestHost $t 'ring1'
        $r = Invoke-TestLab $t @('observe', '-Root', $root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'profile test'
    }

    It 'a reversible module without rollback.ps1 is invalid' {
        Write-TestProfile $t 'observe.norollback'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'missing rollback\.ps1'
    }

    It 'argument errors exit 40' {
        Write-TestProfile $t 'observe.sample'
        (Invoke-TestLab $t @('observe')).Code | Should -Be 40
        (Invoke-TestLab $t @('nope', '-Profile', 'test')).Code | Should -Be 40
        (Invoke-TestLab $t @('observe', '-Profile', 'a;b')).Code | Should -Be 40
        (Invoke-TestLab $t @('observe', '-Profile', 'test', '-Root', 'relative')).Code | Should -Be 40
        (Invoke-TestLab $t @('observe', '-Profile', 'nosuch', '-Root', $root)).Code | Should -Be 40
        (Invoke-TestLab $t @('observe', '-Profile', 'test', '-Bogus')).Code | Should -Be 40
    }

    It '-Version and -Help exit 0' {
        (Invoke-TestLab $t @('-Version')).Code | Should -Be 0
        (Invoke-TestLab $t @('-Help')).Code | Should -Be 0
    }
}
