#Requires -Version 5.1
# Pester 5 tests for keep_on_verify in labyrinth.ps1: a module that only
# takes access away is kept once it verifies and no scored service got
# worse, so the revert timer, and -u without -All, leave it alone
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
        [IO.File]::ReadAllText($notice) | Should -Match "undid run $id"
    }

    It '-u -All undoes kept modules too' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $id = Get-TestRunId $r.Output
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('Nothing else needs undoing.'))
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        $notice | Should -Not -Exist
        [IO.File]::WriteAllText((Join-Path $lab 'tty.in'), "y`n")
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $lab 'tty.out')) | Should -Match ([regex]::Escape("Undo run $($id.Substring($id.Length - 4)) with -All? It also undoes changes kept once verified,"))
        $keeper | Should -Not -Exist
        [IO.File]::ReadAllText($notice) | Should -Match "undid run $id"
    }

    It '-u -All asks first: no answer, or anything but yes, undoes nothing' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $id = Get-TestRunId $r.Output
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $lab 'tty.out')) | Should -BeLike '*`[y/N`] '
        $r.Output | Should -Match ([regex]::Escape('Nothing was undone.'))
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        Get-TestManifest $t $id | Should -Not -Match '"action":"run_rolled_back"'
        Remove-Item -LiteralPath (Join-Path $lab 'tty.pos') -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $lab 'tty.in'), "no`n")
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape('Nothing was undone.'))
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
    }

    It '-u -All with no terminal is refused unless -y answers yes' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $id = Get-TestRunId $r.Output
        Remove-Item -LiteralPath (Join-Path $lab 'tty.out') -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path (Join-Path $lab 'NO_TTY') | Out-Null
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Output | Should -Match ([regex]::Escape('-u -All asks first, and there is no terminal to ask on'))
        $r.Output | Should -Match ([regex]::Escape("To answer yes, add -y: $($t.Self) -u '$($id.Substring($id.Length - 4))' -All -y"))
        (Get-Content -LiteralPath $keeper) | Should -Be 'setting=on'
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-y', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        (Join-Path $lab 'tty.out') | Should -Not -Exist
        $keeper | Should -Not -Exist
        [IO.File]::ReadAllText($notice) | Should -Match "undid run $id"
    }

    It '-u -All asks nothing when the run has no kept module' {
        Write-TestProfile $t 'observe.toggle'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $id = Get-TestRunId $r.Output
        Remove-Item -LiteralPath (Join-Path $lab 'tty.out') -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path (Join-Path $lab 'NO_TTY') | Out-Null
        $r = Invoke-TestLab $t @('-u', $id, '-All', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $toggle | Should -Not -Exist
        (Join-Path $lab 'tty.out') | Should -Not -Exist
    }

    It "the revert timer's own -u never asks, even with no terminal" {
        Write-TestProfile $t @('observe.toggle', 'observe.keeper')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $id = Get-TestRunId $r.Output
        Remove-Item -LiteralPath (Join-Path $lab 'tty.out') -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path (Join-Path $lab 'NO_TTY') | Out-Null
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $toggle | Should -Not -Exist
        (Join-Path $lab 'tty.out') | Should -Not -Exist
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

    It 'help explains -u --all and a kept module' {
        (Invoke-TestLabCapture $t @('-h', 'undo')).Out | Should -Match ([regex]::Escape('--all                  also undo changes kept once they verified'))
        (Invoke-TestLabCapture $t @('-h', 'observe.keeper')).Out | Should -Match 'Kept once it verifies and no scored service got worse'
    }
}
