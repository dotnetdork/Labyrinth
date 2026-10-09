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
        (@($r.Output -split "`r?`n") -ccontains '  Did:       applied and verified') | Should -BeTrue
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

    It 'apply, keep and rollback refuse code or data another account can change' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        New-Item -ItemType File -Path (Join-Path $lab 'UNTRUSTED') | Out-Null
        Remove-Item -LiteralPath $toggle
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 20
        $r.Output | Should -Match ([regex]::Escape("$lab can be changed by an account that is not an administrator"))
        $toggle | Should -Not -Exist
        [IO.File]::WriteAllText($toggle, "setting=on`n")
        foreach ($cmd in 'keep', 'rollback') {
            (Invoke-TestRunCommand $t $cmd $id).Code | Should -Be 20 -Because $cmd
        }
        # Nothing was rolled back, and the timer is still armed.
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
        Join-Path $t.Root "state\runs\$id\timer" | Should -Exist
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
        $r.Output | Should -Match ([regex]::Escape('Break-glass account labadmin: confirmed earlier, so not asked again.'))
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'break-glass: the console session found is recorded; with none, a warning and the run goes on' {
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Match '"action":"breakglass_verified","target":"labadmin".*"note":"console session 1"'
        Remove-Item -LiteralPath (Join-Path $t.Root 'state\breakglass')
        New-Item -ItemType File -Path (Join-Path $lab 'NO_CONSOLE') | Out-Null
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape("warning: no session for labadmin was found at this host's console"))
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Match '"note":"no console session found"'
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
        $r.Output | Should -Match 'its verify script failed'
        (@($r.Output -split "`r?`n") -ccontains '  Did:       rolled back') | Should -BeTrue
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
        $r.Output | Should -Match ([regex]::Escape("To keep later: labyrinth.ps1 keep $($id.Substring($id.Length - 4))"))
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

    It 'an armed revert timer records when it fires' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        $due = ([IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$id\timer-due"))).Trim()
        $due | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    It 'keep that cannot cancel the revert timer keeps nothing and exits 40' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        Add-Content -LiteralPath (Join-Path $lab 'core\Lab.ps1') -Value 'function Unregister-LabRevertTimer { throw ''refused'' }'
        $k = Invoke-TestRunCommand $t 'keep' $id
        $k.Code | Should -Be 40
        $k.Output | Should -Match 'could not be cancelled'
        $k.Output | Should -Not -Match 'kept: the revert timer'
        Join-Path $t.Root "state\runs\$id\timer" | Should -Exist
        Get-TestManifest $t $id | Should -Not -Match '"action":"run_kept"'
    }

    It 'rollback still finishes when the revert timer cannot be removed' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        Add-Content -LiteralPath (Join-Path $lab 'core\Lab.ps1') -Value 'function Unregister-LabRevertTimer { throw ''refused'' }'
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'could not be removed'
        $toggle | Should -Not -Exist
        Get-TestManifest $t $id | Should -Match '"action":"run_rolled_back"'
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
        $r.Output | Should -Match 'a scored service stopped working after the change: web'
        $lines = @($r.Output -split "`r?`n")
        ($lines -ccontains '  Found:     web: fail (fake probe); it passed before') | Should -BeTrue
        ($lines -ccontains '  Did:       rolled back') | Should -BeTrue
        Join-Path $lab 'probe-state' | Should -Not -Exist
    }

    It 'a module that touches scored services is blocked without the scoring allowlist' {
        Write-TestProfile $t @('observe.breaker', 'observe.toggle')
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 20
        (@($r.Output -split "`r?`n") -ccontains 'BLOCKED  Service breaker sample (observe.breaker)') | Should -BeTrue
        Join-Path $lab 'probe-state' | Should -Not -Exist
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'a malformed scoring allowlist is an ERROR with its reason, not an internal error' {
        Write-TestProfile $t @('observe.breaker')
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        Write-TestConfig $t 'scoring-allowlist' @('not-an-address')
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 40
        $lines = @($r.Output -split "`r?`n")
        ($lines -ccontains 'ERROR    Service breaker sample (observe.breaker)') | Should -BeTrue
        ($lines -ccontains '  Problem:   the scoring allowlist is malformed') | Should -BeTrue
        ($lines -ccontains '  Found:     scoring-allowlist:1: not an address or CIDR: not-an-address') | Should -BeTrue
        $r.Output | Should -Not -Match 'internal error'
        $r.Output | Should -Match ([regex]::Escape('apply finished: exit 40 (error)'))
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

    It 'approval: the plan lists each item with its fingerprint and category' {
        Write-TestProfile $t 'observe.ask'
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = @($r.Output -split "`r?`n")
        ($lines -ccontains "  Item:      item-a@2a2c17aaaf66 (sample): first sample item") | Should -BeTrue
        ($lines -ccontains "  Item:      item-c@5821d4d89f00 (other): an item of another category") | Should -BeTrue
    }

    It 'approval: category: approves every item of it; an id not in the plan is ignored' {
        Write-TestProfile $t 'observe.ask'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'category:sample nope item-a', 'keep')
        $r.Code | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $lab 'APPROVED_ITEMS')) | Should -Be @('item-a', 'item-b')
        $r.Output | Should -Match ([regex]::Escape('Not in its plan, so ignored: nope'))
        @($r.Output -split "`r?`n") -ccontains '  Approved:  item-a, item-b' | Should -BeTrue
        $note = "risk approval, approved item-a@2a2c17aaaf66 item-b@f09f429ea5f1"
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Match ([regex]::Escape("`"note`":`"$note`""))
    }

    It 'approval: an answer that is not ids and categories blocks the module' {
        Write-TestProfile $t 'observe.ask'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'item-a;reboot', 'keep')
        $r.Code | Should -Be 20
        @($r.Output -split "`r?`n") -ccontains '  Problem:   not an item id or a category: item-a;reboot' | Should -BeTrue
        Join-Path $lab 'APPROVED_ITEMS' | Should -Not -Exist
    }

    It 'approval: -Approve answers without the prompt; a changed item is refused' {
        Write-TestProfile $t 'observe.ask'
        $a = '2a2c17aaaf66'   # the fixture's fingerprint of item-a
        $list = "observe.ask:item-a@$a,observe.ask:item-b@000000000000,observe.ask:item-z@$a,observe.other:item-a@$a"
        $r = Invoke-TestApply $t @('no') @('-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1', '-Approve', $list)
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'Type the ids'
        @(Get-Content -LiteralPath (Join-Path $lab 'APPROVED_ITEMS')) | Should -Be @('item-a')
        $lines = @($r.Output -split "`r?`n")
        ($lines -ccontains "Not in this run's plan, so ignored: observe.ask:item-z@$a") | Should -BeTrue
        ($lines -ccontains "Not in this run's plan, so ignored: observe.other:item-a@$a") | Should -BeTrue
        ($lines -ccontains '  Found:     item-b changed since the plan, so it is left alone') | Should -BeTrue
        $id = Get-TestRunId $r.Output
        Get-TestManifest $t $id | Should -Match '"action":"approval_refused","target":"item-b"'
        # Approvals are never stored in the revert timer's command line.
        $timer = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$id\timer"))
        $timer | Should -Match " rollback $id "
        $timer | Should -Not -Match 'approve'
    }

    It 'approval: an approval plan with a malformed item line is an ERROR' {
        Write-TestProfile $t 'observe.ask'
        [IO.File]::WriteAllText((Join-Path $lab 'phases\observe\modules\ask\plan.ps1'), "Write-Output `"item``tBad Id``tsample``t2a2c17aaaf66``tx`"`nexit 10`n")
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match ([regex]::Escape('  Problem:   its plan listed an item wrongly'))
        (Invoke-TestApply $t @('labadmin', 'ring1', 'item-a', 'keep')).Code | Should -Be 40
        Join-Path $lab 'APPROVED_ITEMS' | Should -Not -Exist
    }

    It 'secret: a new password is shown only on the console and stored nowhere in the data root' {
        Write-TestProfile $t 'observe.rotate'
        [IO.File]::WriteAllText((Join-Path $lab 'rotate.pw'), "old`n")
        [IO.File]::WriteAllText((Join-Path $lab 'tty.in'), "recorded`n")
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        $shown = [IO.File]::ReadAllText((Join-Path $lab 'tty.out'))
        $shown | Should -Match '(?m)^      ([A-Za-z0-9_.+=-]{20})\r?$'
        $pw = ([regex]::Match($shown, '(?m)^      ([A-Za-z0-9_.+=-]{20})\r?$')).Groups[1].Value
        $shown | Should -Match 'cleared from row'
        $r.Output.Contains($pw) | Should -BeFalse
        foreach ($f in (Get-ChildItem -LiteralPath $t.Root -Recurse -File)) {
            [IO.File]::ReadAllText($f.FullName).Contains($pw) | Should -BeFalse -Because $f.FullName
        }
        [IO.File]::ReadAllText((Join-Path $lab 'rotate.pw')).Trim() | Should -Match '^[0-9a-f]{64}$'
    }

    It 'secret: without a console, the password is not changed' {
        Write-TestProfile $t 'observe.rotate'
        [IO.File]::WriteAllText((Join-Path $lab 'rotate.pw'), "old`n")
        New-Item -ItemType File -Path (Join-Path $lab 'NO_TTY') | Out-Null
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'no terminal to show the new password on'
        [IO.File]::ReadAllText((Join-Path $lab 'rotate.pw')).Trim() | Should -Be 'old'
    }

    It 'secret: a password nobody recorded is put back' {
        Write-TestProfile $t 'observe.rotate'
        [IO.File]::WriteAllText((Join-Path $lab 'rotate.pw'), "old`n")
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'was not recorded'
        [IO.File]::ReadAllText((Join-Path $lab 'rotate.pw')).Trim() | Should -Be 'old'
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

    It 'rollback stops a live run that holds the lock before undoing it' {
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        $holder = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru -WindowStyle Hidden
        try {
            $lock = Join-Path $t.Root 'state\lock'
            New-Item -ItemType Directory -Path $lock -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $lock 'pid'), "$($holder.Id)`n")
            $r = Invoke-TestRunCommand $t 'rollback' $id
            $r.Code | Should -Be 0
            $r.Output | Should -Match "stopping the Labyrinth run \(pid $($holder.Id)\)"
            $r.Output | Should -Not -Match 'without the run lock'
            $holder.WaitForExit(5000) | Should -BeTrue
            (Get-Content -LiteralPath $toggle) | Should -Be 'setting=off'
        } finally {
            if (-not $holder.HasExited) { $holder.Kill() }
        }
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
        $r.Output | Should -Match '\[web\] pass'
        [IO.File]::WriteAllText((Join-Path $lab 'probe-state'), "mail.test fail`n")
        $r = Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 30
        $r.Output | Should -Match '\[mail\] fail'
        $t.Root | Should -Not -Exist
    }
}
