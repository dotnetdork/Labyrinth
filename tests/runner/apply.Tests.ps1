#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 apply, keep, rollback and probe (design 00,
# section 5; design 01, sections 7 to 9; docs/Conventions.md section 3.1).
# The host-specific parts (administrator check, revert timer, probes) are
# test doubles (tests\fixtures\Doubles.ps1); real-system tests are separate.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
}

Describe 'labyrinth.ps1 apply' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $toggle = Join-Path $lab 'toggle.conf'
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        $answers = @('labadmin', 'ring1', 'keep')
    }

    It 'a full apply: gates pass, the change is made, verified, recorded and kept' {
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
        $r.Output | Should -Match '\[observe\.toggle\] applied and verified'
        $r.Output | Should -Match 'kept: the revert timer'
        $m = Get-TestManifest $t (Get-TestRunId $r.Output)
        foreach ($a in 'run_start', 'breakglass_verified', 'apply_start', 'file_created', 'run_kept') {
            $m | Should -Match ('"action":"{0}"' -f $a)
        }
        $timerLog = [IO.File]::ReadAllText((Join-Path $lab 'timer.log'))
        $timerLog | Should -Match '(?m)^arm '
        $timerLog | Should -Match '(?m)^cancel '
    }

    It 'apply writes JSON-lines logs with the contract fields' {
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        $log = (Get-ChildItem -LiteralPath (Join-Path $t.Root 'logs\run') -Filter '*.jsonl' | Get-Content) -join "`n"
        $log | Should -Match ([regex]::Escape('"module":"observe.toggle","entry":"apply","level":"info","event":"toggled"'))
        $log | Should -Match ([regex]::Escape(('"run":"{0}"' -f (Get-TestRunId $r.Output))))
    }

    It 'apply needs an elevated session' {
        New-Item -ItemType File -Path (Join-Path $lab 'NOT_ADMIN') | Out-Null
        (Invoke-TestApply $t $answers).Code | Should -Be 20
        $toggle | Should -Not -Exist
    }

    It 'apply needs this host in the hosts file, and never touches the manual group' {
        Remove-Item -LiteralPath (Join-Path $t.Etc 'hosts')
        (Invoke-TestApply $t $answers).Code | Should -Be 20
        Write-TestHost $t 'manual'
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'manual group'
        $toggle | Should -Not -Exist
    }

    It 'a -Profile that differs from the hosts file is an error' {
        (Invoke-TestApply $t $answers @('-Profile', 'other')).Code | Should -Be 40
    }

    It 'an empty protected set refuses to start' {
        Write-TestConfig $t 'protected-accounts' @()
        (Invoke-TestApply $t $answers).Code | Should -Be 20
        $toggle | Should -Not -Exist
        Join-Path $t.Root 'state\runs' | Should -Not -Exist
    }

    It 'no break-glass confirmation: nothing is changed' {
        (Invoke-TestApply $t @()).Code | Should -Be 20
        $toggle | Should -Not -Exist
        Join-Path $t.Root 'state\runs' | Should -Not -Exist
    }

    It 'the break-glass account must be a breakglass account' {
        (Invoke-TestApply $t @('scoring1', 'ring1', 'keep')).Code | Should -Be 20
        $toggle | Should -Not -Exist
    }

    It 'break-glass is asked once per host' {
        (Invoke-TestApply $t $answers).Code | Should -Be 0
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        $r = Invoke-TestApply $t @('ring1', 'keep')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'break-glass: confirmed earlier for labadmin'
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'a wrong group name: the plan is not confirmed and nothing is changed' {
        (Invoke-TestApply $t @('labadmin', 'ring2')).Code | Should -Be 20
        $toggle | Should -Not -Exist
    }

    It '-BreakGlass and -ConfirmGroup answer the gates without typing' {
        (Invoke-TestApply $t @('keep') @('-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1')).Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'nothing to apply: no gates are asked and nothing is written' {
        Write-TestProfile $t 'observe.clean'
        $r = Invoke-TestApply $t @()
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'nothing to apply'
        Join-Path $t.Root 'state\runs' | Should -Not -Exist
    }

    It 'a plan with errors applies nothing' {
        Write-TestProfile $t @('observe.toggle', 'observe.crash')
        (Invoke-TestApply $t $answers).Code | Should -Be 40
        $toggle | Should -Not -Exist
    }

    It 'a forced verify failure rolls the module back' {
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 30
        $r.Output | Should -Match 'verify failed'
        $r.Output | Should -Match '\[observe\.toggle\] rolled back'
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=off'
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Match '"action":"rolled_back"'
    }

    It 'an apply error after a partial change rolls the module back' {
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_APPLY') | Out-Null
        (Invoke-TestApply $t $answers).Code | Should -Be 40
        $toggle | Should -Not -Exist
    }

    It 'a failure stops the run: later modules are not applied' {
        Write-TestProfile $t @('observe.toggle', 'observe.ask')
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'item-a')
        $r.Code | Should -Be 30
        Join-Path $lab 'APPROVED_ITEMS' | Should -Not -Exist
        $r.Output | Should -Match 'The run stopped'
    }

    It 'not kept: the revert timer stays armed, and when it fires the run is rolled back' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Not kept'
        $id = Get-TestRunId $r.Output
        $runDir = Join-Path $t.Root "state\runs\$id"
        $timerCmd = [IO.File]::ReadAllText((Join-Path $runDir 'timer'))
        $timerCmd | Should -Match ([regex]::Escape(('labyrinth.ps1" rollback {0} -Root "{1}" -Config "{2}"' -f $id, $t.Root, $t.Etc)))
        # The timer firing runs exactly this command.
        (Invoke-TestRunCommand $t 'rollback' $id).Code | Should -Be 0
        $toggle | Should -Not -Exist
        Join-Path $runDir 'timer' | Should -Not -Exist
        Get-TestManifest $t $id | Should -Match '"action":"run_rolled_back"'
        # Keeping after the timer fired is too late.
        $k = Invoke-TestRunCommand $t 'keep' $id
        $k.Code | Should -Be 20
        $k.Output | Should -Match 'too late'
    }

    It 'rollback is safe to run twice' {
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        (Invoke-TestRunCommand $t 'rollback' $id).Code | Should -Be 0
        (Invoke-TestRunCommand $t 'rollback' $id).Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=off'
    }

    It 'keep later cancels the timer' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        (Invoke-TestRunCommand $t 'keep' $id).Code | Should -Be 0
        Join-Path $t.Root "state\runs\$id\timer" | Should -Not -Exist
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'keep and rollback reject bad run ids and unknown runs' {
        (Invoke-TestRunCommand $t 'keep' '..\x').Code | Should -Be 40
        (Invoke-TestRunCommand $t 'rollback' '20260101T000000Z-abcd').Code | Should -Be 40
    }

    It 'a scored service that regresses rolls the module back and stops the run' {
        Write-TestProfile $t 'observe.breaker'
        Write-TestConfig $t 'services' @('mail smtp mail.test 25 -', 'web http web.test 80 -')
        Write-TestConfig $t 'scoring-allowlist' @('198.51.100.0/28')
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 30
        $r.Output | Should -Match 'scored service regressed: web'
        $r.Output | Should -Match '\[observe\.breaker\] rolled back'
        Join-Path $lab 'probe-state' | Should -Not -Exist
    }

    It 'a module that touches scored services is blocked without the scoring allowlist' {
        Write-TestProfile $t @('observe.breaker', 'observe.toggle')
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 20
        $r.Output | Should -Match '\[observe\.breaker\] blocked'
        Join-Path $lab 'probe-state' | Should -Not -Exist
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'an approval module changes only what a person approves' {
        Write-TestProfile $t 'observe.ask'
        $items = Join-Path $lab 'APPROVED_ITEMS'
        (Invoke-TestApply $t @('labadmin', 'ring1', 'item-a', 'keep')).Code | Should -Be 0
        (Get-Content -LiteralPath $items) | Should -Be 'item-a'
        Remove-Item -LiteralPath $items
        $r = Invoke-TestApply $t @('ring1', '', 'keep')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'nothing approved'
        $items | Should -Not -Exist
    }

    It 'a manual-only module is never applied' {
        Write-TestProfile $t 'observe.manual'
        $r = Invoke-TestApply $t @()
        $r.Output | Should -Match 'checklist'
        $r.Output | Should -Match 'nothing to apply'
    }

    It 'a run lock held by a live process blocks apply' {
        $lock = Join-Path $t.Root 'state\lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $lock 'pid'), "$PID`n")
        (Invoke-TestApply $t $answers).Code | Should -Be 20
        $toggle | Should -Not -Exist
    }

    It 'a stale run lock is taken over' {
        $lock = Join-Path $t.Root 'state\lock'
        New-Item -ItemType Directory -Path $lock -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $lock 'pid'), "999999`n")
        (Invoke-TestApply $t $answers).Code | Should -Be 0
        $lock | Should -Not -Exist
    }

    It 'probe reports every service and exits 30 when one fails' {
        Write-TestConfig $t 'services' @('web http web.test 80 -', 'mail smtp mail.test 25 -')
        $r = Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'web pass'
        [IO.File]::WriteAllText((Join-Path $lab 'probe-state'), "mail.test fail`n")
        $r = Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 30
        $r.Output | Should -Match 'mail fail'
        $t.Root | Should -Not -Exist
    }
}
