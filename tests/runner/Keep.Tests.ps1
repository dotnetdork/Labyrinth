#Requires -Version 5.1
# Pester 5 tests for keep_on_verify in labyrinth.ps1: a module that only
# takes access away is kept once it verifies and no scored service got
# worse, so the revert timer, and rollback without -All, leave it alone
# (docs\Conventions.md section 3.1). The host-specific parts are test
# doubles (tests\fixtures\Doubles.ps1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
}

Describe 'labyrinth.ps1 keep_on_verify' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $keeper = Join-Path $lab 'keeper.conf'
        $toggle = Join-Path $lab 'toggle.conf'
        $notice = Join-Path $lab 'notice.log'
        $yml = Join-Path $lab 'phases\observe\modules\keeper\module.yml'
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.keeper'
        Write-TestConfig $t 'services' @('web http web.test 80 -')
    }

    It 'a module kept once verified is recorded, and a run with only such changes is kept without asking' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 0
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        $r.Output | Should -Match ([regex]::Escape('Did:       kept: it verified and no scored service got worse'))
        $r.Output | Should -Match ([regex]::Escape('All changes are applied, verified and kept.'))
        $r.Output | Should -Not -Match 'Type keep to keep'
        $id = Get-TestRunId $r.Output
        $m = Get-TestManifest $t $id
        $m | Should -Match '"module":"observe\.keeper".*"action":"module_kept"'
        $m | Should -Match '"action":"run_kept"'
        (Join-Path $t.Root "state\runs\$id\timer") | Should -Not -Exist
    }

    It 'the recap says which changes are kept once they verify' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Output | Should -Match 'A change that only takes access away is kept once it verifies'
    }

    It 'the revert timer undoes the other changes and leaves a kept module in place' {
        Write-TestProfile $t @('observe.toggle', 'observe.keeper')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Type keep to keep'
        $id = Get-TestRunId $r.Output
        # The command the timer runs.
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('Kept once verified, so left in place (add -All to undo these too):'))
        $r.Output | Should -Match ([regex]::Escape('  Keeper setting sample (observe.keeper)'))
        $toggle | Should -Not -Exist
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        [IO.File]::ReadAllText($notice) | Should -Match "rolled back run $id"
    }

    It 'rollback -All undoes kept modules too' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $id = Get-TestRunId $r.Output
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('Nothing else needs undoing.'))
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        $notice | Should -Not -Exist
        $r = Invoke-TestLab $t @('rollback', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $keeper | Should -Not -Exist
        [IO.File]::ReadAllText($notice) | Should -Match "rolled back run $id"
    }

    It 'with no service list, nothing is kept early and the timer still covers it' {
        Remove-Item -LiteralPath (Join-Path $t.Etc 'services')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('Note:      not kept yet: with no service list'))
        $r.Output | Should -Match 'Type keep to keep'
        $id = Get-TestRunId $r.Output
        Get-TestManifest $t $id | Should -Not -Match '"action":"module_kept"'
        [void](Invoke-TestRunCommand $t 'rollback' $id)
        $keeper | Should -Not -Exist
    }

    It 'a module whose verify fails is rolled back, never kept' {
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 30
        $keeper | Should -Not -Exist
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Not -Match '"action":"module_kept"'
    }

    It 'a module that breaks a scored service is rolled back, never kept' {
        $apply = Join-Path $lab 'phases\observe\modules\keeper\apply.ps1'
        $text = [IO.File]::ReadAllText($apply)
        $break = "[IO.File]::WriteAllText((Join-Path `$env:LAB_ROOT 'probe-state'), ""web.test fail``n"")`r`nWrite-Output 'keeper: setting=on'"
        [IO.File]::WriteAllText($apply, $text.Replace("Write-Output 'keeper: setting=on'", $break))
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 30
        $keeper | Should -Not -Exist
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Not -Match '"action":"module_kept"'
    }

    It 'keep_on_verify is refused on a module that changes nothing' {
        [IO.File]::WriteAllText($yml, [IO.File]::ReadAllText($yml).Replace('risk: reversible', 'risk: read-only'))
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'keep_on_verify is only for a module that changes'
    }

    It 'keep_on_verify must be true or false' {
        [IO.File]::WriteAllText($yml, [IO.File]::ReadAllText($yml).Replace('keep_on_verify: true', 'keep_on_verify: yes'))
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'keep_on_verify must be true or false'
    }

    It 'help explains rollback -All and a kept module' {
        (Invoke-TestLabCapture $t @('help', 'rollback')).Out | Should -Match ([regex]::Escape('-All                   also undo changes kept once they verified'))
        (Invoke-TestLabCapture $t @('help', 'observe.keeper')).Out | Should -Match 'Kept once it verifies and no scored service got worse'
    }
}
