#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -Extend ID: it adds one timer length
# (REVERT_MINUTES) to the time left on a run's revert timer, only for a run
# whose timer is armed, and records each extension (docs\Conventions.md
# section 3.1). The revert timer is a test double (tests\fixtures\Doubles.ps1)
# that writes timer-due and logs each arming to timer.log. Mirrors extend.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Invoke-TestLabRun T ARGS: labyrinth.ps1 with the test data root.
    function Invoke-TestLabRun {
        param($T, [string[]] $Arguments)
        Invoke-TestLabCapture $T (@($Arguments) + @('-Root', $T.Root, '-Config', $T.Etc))
    }

    # Get-TestArmedRun T: apply, leave the revert timer armed, and return
    # the run ID. Break-glass is asked only on the first apply.
    function Get-TestArmedRun {
        param($T)
        Remove-Item -LiteralPath (Join-Path $T.Lab 'toggle.conf') -ErrorAction SilentlyContinue
        $answers = @('labadmin', 'ring1', 'no')
        if (Test-Path -LiteralPath (Join-Path $T.Root 'state\runs')) { $answers = @('ring1', 'no') }
        $r = Invoke-TestApply $T $answers
        $r.Code | Should -Be 0
        return Get-TestRunId $r.Output
    }

    function Get-TestSuffix { param([string] $Id) return $Id.Substring($Id.Length - 4) }

    # Set-TestFireIn T RUN SECONDS: make the run's timer fire SECONDS from now.
    function Set-TestFireIn {
        param($T, [string] $RunId, [int] $Seconds)
        $due = [DateTime]::UtcNow.AddSeconds($Seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::WriteAllText((Join-Path $T.Root "state\runs\$RunId\timer-due"), "$due`n")
    }

    # Get-TestLeft T RUN: the whole seconds until the run's timer-due.
    function Get-TestLeft {
        param($T, [string] $RunId)
        $text = ([IO.File]::ReadAllText((Join-Path $T.Root "state\runs\$RunId\timer-due"))).Trim()
        $due = [DateTime]::ParseExact($text, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        return [int]($due - [DateTime]::UtcNow).TotalSeconds
    }

    # Get-TestArmLine T: the timer.log lines that arm a timer.
    function Get-TestArmLine {
        param($T)
        $f = Join-Path $T.Lab 'timer.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @(Get-Content -LiteralPath $f | Where-Object { $_ -like 'arm *' })
    }
}

Describe 'labyrinth.ps1 -Extend' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'adds one timer length to the time left, and a second extension adds another' {
        $a = Get-TestArmedRun $t
        Set-TestFireIn $t $a 120
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Timer:  now fires \d\d:\d\d UTC \(in 7 minutes\)'
        $n = Get-TestLeft $t $a
        $n | Should -BeGreaterOrEqual 415
        $n | Should -BeLessOrEqual 425
        (Get-TestArmLine $t)[-1] | Should -Match "^arm $a 4[0-2]\d$"
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '\(in 12 minutes\)'
        $n = Get-TestLeft $t $a
        $n | Should -BeGreaterOrEqual 715
        $n | Should -BeLessOrEqual 725
        (Get-TestArmLine $t)[-1] | Should -Match "^arm $a 7[0-2]\d$"
    }

    It 'the timer length is REVERT_MINUTES from event.conf' {
        $a = Get-TestArmedRun $t
        Write-TestConfig $t 'event.conf' @('REVERT_MINUTES=3')
        Set-TestFireIn $t $a 60
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '\(in 4 minutes\)'
        (Get-TestArmLine $t)[-1] | Should -Match "^arm $a 2[34]\d$"
    }

    It 'a timer past due, or with no known time, is set one timer length from now' {
        $a = Get-TestArmedRun $t
        $due = Join-Path $t.Root "state\runs\$a\timer-due"
        [IO.File]::WriteAllText($due, "2000-01-01T00:05:00Z`n")
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '\(in 5 minutes\)'
        Remove-Item -LiteralPath $due
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '\(in 5 minutes\)'
    }

    It 'prints the new time and the keep command, and does not keep or undo the run' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('-Extend', (Get-TestSuffix $a))
        $r.Code | Should -Be 0
        $r.Out | Should -Match "using run $a"
        $r.Out | Should -Match '(?m)^Timer:  now fires '
        $r.Out | Should -Match ([regex]::Escape("Next:   $($t.Self) -k '$(Get-TestSuffix $a)'"))
        [IO.File]::ReadAllText((Join-Path $t.Lab 'toggle.conf')) | Should -Match 'setting=on'
        Join-Path $t.Root "state\runs\$a\timer" | Should -Exist
    }

    It 'a kept run is refused, and nothing is armed' {
        $a = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('-k', $a)).Code | Should -Be 0
        $before = (Get-TestArmLine $t).Count
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match "run $a was already kept, so it has no revert timer to extend"
        (Get-TestArmLine $t).Count | Should -Be $before
        Get-TestManifest $t $a | Should -Not -Match 'timer_extended'
    }

    It 'an undone run is refused, like -k' {
        $a = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('-u', $a)).Code | Should -Be 0
        $before = (Get-TestArmLine $t).Count
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match "too late: run $a was already undone"
        (Get-TestArmLine $t).Count | Should -Be $before
        Get-TestManifest $t $a | Should -Not -Match 'timer_extended'
    }

    It 'a run made with -NoRevert is refused, and the message gives the undo command' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1') @('-NoRevert')
        $r.Code | Should -Be 0
        $a = Get-TestRunId $r.Output
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape("run $a has no revert timer (-NoRevert), so there is nothing to extend"))
        $r.Err | Should -Match ([regex]::Escape("To undo it: $($t.Self) -u '$(Get-TestSuffix $a)'"))
        Join-Path $t.Lab 'timer.log' | Should -Not -Exist
        Get-TestManifest $t $a | Should -Not -Match 'timer_extended'
    }

    It 'a run with no armed timer at all is refused' {
        $a = Get-TestArmedRun $t
        Remove-Item -LiteralPath (Join-Path $t.Root "state\runs\$a\timer")
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match "run $a has no armed revert timer to extend"
    }

    It 'a time after the ID is a usage error and arms nothing' {
        $a = Get-TestArmedRun $t
        $before = (Get-TestArmLine $t).Count
        $r = Invoke-TestLabRun $t @('-Extend', $a, '10')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape('-Extend takes no time: each call adds one timer length'))
        $r.Err | Should -Match ([regex]::Escape("To add more, run it again: $($t.Self) -Extend $a"))
        $r.Err | Should -Match ([regex]::Escape("Try '$($t.Self) -Extend -h'."))
        (Invoke-TestLabRun $t @('-Extend', (Get-TestSuffix $a), '10m')).Code | Should -Be 40
        (Get-TestArmLine $t).Count | Should -Be $before
    }

    It '-Extend without an ID lists the armed runs and extends none' {
        $a = Get-TestArmedRun $t
        $before = (Get-TestArmLine $t).Count
        $r = Invoke-TestLabRun $t @('-Extend')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "(?s)$a.*-Extend needs a run ID, or its last 4 characters"
        $r.Err | Should -Match 'pick one from the list above'
        (Get-TestArmLine $t).Count | Should -Be $before
    }

    It '-Extend without an ID and no armed run is still a usage error' {
        $r = Invoke-TestLabRun $t @('-Extend')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape('-Extend needs a run ID, or its last 4 characters'))
        $r.Err | Should -Match ([regex]::Escape('No run on this host has an armed revert timer.'))
    }

    It '-Extend needs an Administrator, and a run that does not exist is an error' {
        $a = Get-TestArmedRun $t
        $flag = Join-Path $t.Lab 'NOT_ADMIN'
        New-Item -ItemType File -Path $flag | Out-Null
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match '-Extend needs an elevated Administrator session'
        Remove-Item -LiteralPath $flag
        $r = Invoke-TestLabRun $t @('-Extend', 'beef')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "no run ending in 'beef'"
    }

    It 'a failed re-arm leaves the earlier timer as it was, exits 40 and records nothing' {
        $a = Get-TestArmedRun $t
        Set-TestFireIn $t $a 120
        $timer = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer"))
        $due = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer-due"))
        [IO.File]::AppendAllText((Join-Path $t.Lab 'core\Lab.ps1'), "`nfunction Register-LabRevertTimer { throw 'task scheduler is down' }`n")
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 40
        $r.Err | Should -Match "the revert timer for run $a could not be extended"
        $r.Err | Should -Match 'The earlier timer is unchanged and still undoes the run at '
        $r.Err | Should -Match ([regex]::Escape("Retry: $($t.Self) -Extend '$(Get-TestSuffix $a)'"))
        [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer")) | Should -BeExactly $timer
        [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer-due")) | Should -BeExactly $due
        Get-TestManifest $t $a | Should -Not -Match 'timer_extended'
    }

    It 'each extension is in the run log, the manifest and the event log' {
        $a = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('-Extend', $a)).Code | Should -Be 0
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $m = Get-TestManifest $t $a
        ([regex]::Matches($m, '"action":"timer_extended"')).Count | Should -Be 2
        $m | Should -Match '"action":"timer_extended".*"note":"added 5 minutes; now fires 20'
        $log = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\output.log"))
        ([regex]::Matches($log, ': extend run ' + $a)).Count | Should -Be 2
        ([regex]::Matches($log, '(?m)^Timer:  now fires ')).Count | Should -Be 2
        $r.Out | Should -Match ([regex]::Escape("Log: $(Join-Path $t.Root "state\runs\$a\output.log")"))
        $events = (Get-ChildItem -LiteralPath (Join-Path $t.Root 'logs\run') -Filter '*.jsonl' | Get-Content) -join "`n"
        ([regex]::Matches($events, '"event":"timer_extended"')).Count | Should -Be 2
    }

    It '-History, the status and -Show give the new fire time' {
        $a = Get-TestArmedRun $t
        Set-TestFireIn $t $a 120
        (Invoke-TestLabRun $t @('-Extend', $a)).Code | Should -Be 0
        $due = ([IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer-due"))).Trim()
        $at = $due.Substring(11, 5)
        (Invoke-TestLabRun $t @('-History')).Out | Should -Match "armed: undo at $at UTC"
        (Invoke-TestLabRun $t @()).Out | Should -Match "Timer:    run $(Get-TestSuffix $a) is undone at $at UTC, in 7 minutes"
        (Invoke-TestLabRun $t @('-Show', $a)).Out | Should -Match "(?m)^  State:     armed: undo at $at UTC"
    }

    It "extending a run does not touch another run's timer" {
        $a = Get-TestArmedRun $t
        $b = Get-TestArmedRun $t
        Set-TestFireIn $t $a 120
        Set-TestFireIn $t $b 120
        (Invoke-TestLabRun $t @('-Extend', $a)).Code | Should -Be 0
        Get-TestLeft $t $b | Should -BeLessOrEqual 120
        Get-TestLeft $t $a | Should -BeGreaterOrEqual 415
    }

    It 'the command the timer runs still undoes an extended run, and extending it then is too late' {
        $a = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('-Extend', $a)).Code | Should -Be 0
        (Invoke-TestLabRun $t @('-u', $a)).Code | Should -Be 0
        Join-Path $t.Lab 'toggle.conf' | Should -Not -Exist
        (Invoke-TestLabRun $t @('-Extend', $a)).Code | Should -Be 20
    }
}
