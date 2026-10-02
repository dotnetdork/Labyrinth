#Requires -Version 5.1
# Compatibility suite for labyrinth.ps1 (docs/Conventions.md section 3.1).
# Every command form here works today and must keep working: operators
# have learned them, and an armed revert timer runs its stored command
# line long after the runner that armed it was replaced. Change the
# runner, never this file, to make a change pass.
#
# Checked here: exit codes, the stored timer line, the prompt order and
# the run header. Wording of help and errors is not checked here.
# Pinned output text that other suites own: "applied and verified",
# "kept: the revert timer", "rolled back", "The run stopped", "Not kept",
# "too late", "nothing approved", "nothing to apply", "checklist"
# (apply.Tests.ps1); "check: nothing to do", "unknown key color",
# "protected set is not loaded" (labyrinth.Tests.ps1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Invoke-TestLabSession T COMMAND: run COMMAND inside a PowerShell
    # session, as an operator typing at the prompt would; LAB is the script.
    function Invoke-TestLabSession {
        param($T, [string] $Command)
        $ps1 = Join-Path $T.Lab 'labyrinth.ps1'
        $line = "`$LAB = '$ps1'; $Command; exit `$LASTEXITCODE"
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $line 2>&1
            return $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
    }
}

Describe 'labyrinth.ps1 compatibility' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $toggle = Join-Path $lab 'toggle.conf'
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        $answers = @('labadmin', 'ring1', 'keep')
    }

    It 'compat: a bare phase plans, with options before or after it' {
        (Invoke-TestLab $t @('observe', '-Profile', 'test', '-Root', $t.Root, '-Config', $t.Etc)).Code | Should -Be 10
        (Invoke-TestLab $t @('-Profile', 'test', '-Root', $t.Root, '-Config', $t.Etc, 'observe')).Code | Should -Be 10
        (Invoke-TestLab $t @('-Profile', 'test', 'observe', '-Root', $t.Root, '-Config', $t.Etc)).Code | Should -Be 10
        $t.Root | Should -Not -Exist
    }

    It 'compat: -ProfileName and lower-case option names work' {
        (Invoke-TestLab $t @('observe', '-ProfileName', 'test', '-Root', $t.Root, '-Config', $t.Etc)).Code | Should -Be 10
        (Invoke-TestLab $t @('observe', '-profile', 'test', '-root', $t.Root, '-config', $t.Etc)).Code | Should -Be 10
    }

    It 'compat: -Apply before or after the phase applies' {
        (Invoke-TestLab $t @('observe', '-Apply', '-Root', $t.Root, '-Config', $t.Etc) -Answers $answers).Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        (Invoke-TestLab $t @('-Apply', 'observe', '-Root', $t.Root, '-Config', $t.Etc) -Answers @('ring1', 'keep')).Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'compat: -BreakGlass and -ConfirmGroup answer the gates' {
        $a = @('observe', '-Apply', '-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1', '-Root', $t.Root, '-Config', $t.Etc)
        (Invoke-TestLab $t $a -Answers @('keep')).Code | Should -Be 0
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'compat: the stored revert-timer command line runs a rollback' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $runDir = Join-Path $t.Root "state\runs\$id"
        $line = [IO.File]::ReadAllText((Join-Path $runDir 'timer')).TrimEnd()
        $line | Should -Match ([regex]::Escape(('labyrinth.ps1" rollback {0} -Root "{1}" -Config "{2}"' -f $id, $t.Root, $t.Etc)))
        $line.StartsWith("$script:HostExe ") | Should -Be $true
        # Run the stored command line exactly as Task Scheduler would.
        $psi = New-Object Diagnostics.ProcessStartInfo($script:HostExe, $line.Substring($script:HostExe.Length + 1))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        $null = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $null = $errTask.Result
        $p.ExitCode | Should -Be 0
        Get-TestManifest $t $id | Should -Match '"action":"run_rolled_back"'
        $toggle | Should -Not -Exist
    }

    It 'compat: keep <run> and rollback <run> take options before or after' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        (Invoke-TestLab $t @('-Root', $t.Root, '-Config', $t.Etc, 'keep', $id)).Code | Should -Be 0
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        $id = Get-TestRunId (Invoke-TestApply $t @('ring1', 'no')).Output
        (Invoke-TestLab $t @('rollback', $id, '-Root', $t.Root, '-Config', $t.Etc)).Code | Should -Be 0
        (Invoke-TestLab $t @('-Root', $t.Root, '-Config', $t.Etc, 'rollback', $id)).Code | Should -Be 0
        $k = Invoke-TestLab $t @('keep', $id, '-Root', $t.Root, '-Config', $t.Etc)
        $k.Code | Should -Be 20
        $k.Output | Should -Match 'too late'
    }

    It 'compat: forms typed inside a PowerShell session work' {
        $o = "-Root '$($t.Root)' -Config '$($t.Etc)'"
        Invoke-TestLabSession $t "& `$LAB observe -Profile test $o" | Should -Be 10
        Invoke-TestLabSession $t "& `$LAB observe -Profile:test -Root:'$($t.Root)' -Config:'$($t.Etc)'" | Should -Be 10
        Invoke-TestLabSession $t "& `$LAB -Version" | Should -Be 0
        Invoke-TestLabSession $t "& `$LAB nosuchphase $o" | Should -Be 40
        $t.Root | Should -Not -Exist
    }

    It 'compat: the prompts come in order: break-glass, group, approval, keep' {
        Write-TestProfile $t 'observe.ask'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'item-a', 'keep')
        $r.Code | Should -Be 0
        $prev = -1
        foreach ($p in 'Break-glass check:', 'Type the group name (ring1)', 'Type the ids of the items', 'Type keep to keep') {
            $at = $r.Output.IndexOf($p)
            $at | Should -BeGreaterThan $prev -Because "the prompt '$p' comes next"
            $prev = $at
        }
    }

    It "compat: the run header names the run, and apply's run is the one recorded" {
        (Invoke-TestPlan $t).Output | Should -Match 'run \d{8}T\d{6}Z-[0-9a-f]{4}'
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        Join-Path $t.Root ('state\runs\{0}' -f (Get-TestRunId $r.Output)) | Should -Exist
    }

    It 'compat: -Version and -Help exit 0' {
        (Invoke-TestLab $t @('-Version')).Code | Should -Be 0
        (Invoke-TestLab $t @('-Help')).Code | Should -Be 0
    }

    It 'compat: argument errors exit 40' {
        $o = @('-Root', $t.Root, '-Config', $t.Etc)
        (Invoke-TestLab $t (@('nosuchphase') + $o)).Code | Should -Be 40
        (Invoke-TestLab $t @('observe', '-Root', 'relative\root', '-Config', $t.Etc)).Code | Should -Be 40
        (Invoke-TestLab $t (@('observe', '-Profile', 'a;b') + $o)).Code | Should -Be 40
        (Invoke-TestLab $t (@('keep', '..\x') + $o)).Code | Should -Be 40
        (Invoke-TestLab $t (@('rollback', '20260101T000000Z-abcd') + $o)).Code | Should -Be 40
        (Invoke-TestLab $t (@('probe', 'extra') + $o)).Code | Should -Be 40
        (Invoke-TestLab $t (@('observe', '-Bogus') + $o)).Code | Should -Be 40
        $toggle | Should -Not -Exist
    }

    It 'compat: probe exits 0, then 30 when a service fails, and writes nothing' {
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        (Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)).Code | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $lab 'probe-state'), "web.test fail`n")
        (Invoke-TestLab $t @('-Root', $t.Root, '-Config', $t.Etc, 'probe')).Code | Should -Be 30
        $t.Root | Should -Not -Exist
    }
}
