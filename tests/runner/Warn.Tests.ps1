#Requires -Version 5.1
# Pester 5 tests for the warning before the revert timer undoes a run: every
# run that arms the timer arms a warning with it, -Extend moves it, -k and -u
# remove it, and the hidden entry 'labyrinth.ps1 --warn' the warning's own
# task runs tells whoever is logged in (docs\Conventions.md section 3.1). The
# timer, the warning's arming and the notice are test doubles
# (tests\fixtures\Doubles.ps1), which record each arming of the warning in
# warn.log and each notice in notice.log. Mirrors warn.bats.

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

    # Invoke-TestWarn T RUN [NAME]: what the warning's task runs.
    function Invoke-TestWarn {
        param($T, [string] $RunId, [string] $Name = 'laby')
        Invoke-TestLabCapture $T @('--warn', $RunId, $T.Root, $T.Etc, $Name)
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

    # Write-TestFireIn T RUN SECONDS: make the run's timer fire SECONDS from now.
    function Write-TestFireIn {
        param($T, [string] $RunId, [int] $Seconds)
        $due = [DateTime]::UtcNow.AddSeconds($Seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::WriteAllText((Join-Path $T.Root "state\runs\$RunId\timer-due"), "$due`n")
    }

    # Get-TestWarnLog T: the lines of warn.log.
    function Get-TestWarnLog {
        param($T)
        $f = Join-Path $T.Lab 'warn.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @(Get-Content -LiteralPath $f)
    }

    function Get-TestNotice {
        param($T)
        $f = Join-Path $T.Lab 'notice.log'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @(Get-Content -LiteralPath $f)
    }

    function Get-TestStructuredLog {
        param($T)
        $dir = Join-Path $T.Root 'logs\run'
        if (-not (Test-Path -LiteralPath $dir)) { return '' }
        return (@(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
    }
}

Describe 'the warning before the revert timer undoes a run' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'an apply arms the warning with the timer, for the same time, running the hidden entry' {
        $a = Get-TestArmedRun $t
        $arm = @(Get-TestWarnLog $t | Where-Object { $_ -like 'arm *' })
        $arm.Count | Should -Be 1
        $arm[0] | Should -Match "^arm $a 300 .* --warn $a "
        $arm[0] | Should -BeLike '*labyrinth.ps1"'
        Join-Path $t.Root "state\runs\$a\warn" | Should -Exist
    }

    It 'the warning names the installed launcher when the run was started through it' {
        $env:LAB_SELF = 'laby'
        try {
            $a = Get-TestArmedRun $t
        } finally {
            Remove-Item Env:\LAB_SELF -ErrorAction SilentlyContinue
        }
        @(Get-TestWarnLog $t | Where-Object { $_ -like 'arm *' })[0] | Should -BeLike '* --warn *"laby"'
    }

    It 'a timer shorter than two minutes still gets a warning, at the halfway point' {
        Write-TestConfig $t 'event.conf' @('REVERT_MINUTES=1')
        $a = Get-TestArmedRun $t
        @(Get-TestWarnLog $t | Where-Object { $_ -like 'arm *' })[0] | Should -BeLike "arm $a 60 *"
        Join-Path $t.Root "state\runs\$a\warn" | Should -Exist
    }

    It 'extending moves the warning with the timer' {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 120
        $before = @(Get-TestWarnLog $t | Where-Object { $_ -like 'arm *' }).Count
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $arm = @(Get-TestWarnLog $t | Where-Object { $_ -like 'arm *' })
        $arm.Count | Should -Be ($before + 1)
        $arm[-1] | Should -Match "^arm $a 4[0-2]\d .* --warn $a "
        Join-Path $t.Root "state\runs\$a\warn" | Should -Exist
    }

    It 'keeping a run removes the warning' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestRunCommand $t 'keep' $a
        $r.Code | Should -Be 0
        Join-Path $t.Root "state\runs\$a\warn" | Should -Not -Exist
        (Get-TestWarnLog $t)[-1] | Should -Be "cancel $a"
    }

    It 'undoing a run, as the timer does, removes the warning' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestRunCommand $t 'rollback' $a
        $r.Code | Should -Be 0
        Join-Path $t.Root "state\runs\$a\warn" | Should -Not -Exist
        (Get-TestWarnLog $t)[-1] | Should -Be "cancel $a"
    }

    It 'a warning that cannot be armed never stops the run, and the timer is still armed' {
        [IO.File]::WriteAllText((Join-Path $t.Lab 'WARN_FAIL'), '')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $a = Get-TestRunId $r.Output
        $r.Output | Should -Match 'Note:\s+the warning before the undo was not set up; the timer is armed'
        Join-Path $t.Root "state\runs\$a\timer" | Should -Exist
        Join-Path $t.Root "state\runs\$a\warn" | Should -Not -Exist
        [IO.File]::ReadAllText((Join-Path $t.Lab 'toggle.conf')) | Should -Match 'setting=on'
        $r = Invoke-TestLabRun $t @('-Extend', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '(?m)^Note:   the warning before the undo was not set up; the timer is armed?$'
        $r.Out | Should -Match '(?m)^Next:   '
    }

    It 'the warning names the run, the host, the time, and the keep and extend commands' {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 60
        $suffix = $a.Substring($a.Length - 4)
        $at = ([IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\timer-due"))).Substring(11, 5)
        $r = Invoke-TestWarn $t $a 'laby'
        $r.Code | Should -Be 0
        $n = Get-TestNotice $t
        $n | Should -Contain "Labyrinth undoes run $suffix on $script:ThisHost at $at UTC (in 1 minute)."
        @($n | Where-Object { $_ -like "To keep it:      laby -k '$suffix'*" }).Count | Should -Be 1
        @($n | Where-Object { $_ -like "To get 5 more:   laby -Extend '$suffix'*" }).Count | Should -Be 1
        # The data folders differ from the defaults, so the commands carry them.
        @($n | Where-Object { $_ -like '*-Root *' -and $_ -like '*-Config *' }).Count | Should -Be 2
        # It changes nothing: the changes and the timer stay.
        [IO.File]::ReadAllText((Join-Path $t.Lab 'toggle.conf')) | Should -Match 'setting=on'
        Join-Path $t.Root "state\runs\$a\timer" | Should -Exist
        ([IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\manifest.jsonl"))) | Should -Not -Match 'timer_warned'
    }

    It 'the extend command in the warning gives the timer length from event.conf' {
        Write-TestConfig $t 'event.conf' @('REVERT_MINUTES=10')
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 60
        $r = Invoke-TestWarn $t $a
        $r.Code | Should -Be 0
        @(Get-TestNotice $t | Where-Object { $_ -like 'To get 10 more:  laby -Extend *' }).Count | Should -Be 1
    }

    It "a short timer's warning says how many seconds are left" {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 45
        $r = Invoke-TestWarn $t $a
        $r.Code | Should -Be 0
        (Get-TestNotice $t)[0] | Should -Match "^Labyrinth undoes run $($a.Substring($a.Length - 4)) on .* at \d\d:\d\d UTC \(in 4[0-5] seconds\)\.$"
    }

    It 'the warning is recorded in the run log and the log of runs' {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 60
        $r = Invoke-TestWarn $t $a
        $r.Code | Should -Be 0
        $r.Out | Should -Match "warned the sessions logged in that the revert timer undoes run $a in "
        $log = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$a\output.log"))
        $log | Should -Match "(?m): warn run $a$"
        $log | Should -Match 'warned the sessions logged in'
        Get-TestStructuredLog $t | Should -Match '"event":"timer_warned"'
    }

    It 'a missing msg does not fail the warning, and the log says it was not sent' {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 60
        [IO.File]::WriteAllText((Join-Path $t.Lab 'NO_WALL'), '')
        $r = Invoke-TestWarn $t $a
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'could not warn the sessions logged in'
        Join-Path $t.Lab 'notice.log' | Should -Not -Exist
        Get-TestStructuredLog $t | Should -Match 'revert timer warning not sent'
    }

    It 'no warning is sent for a run that is kept or undone, or whose timer is not near' {
        $a = Get-TestArmedRun $t
        # Not due within a minute and a half: an earlier timer's warning, or a restart.
        Write-TestFireIn $t $a 200
        (Invoke-TestWarn $t $a).Code | Should -Be 0
        Join-Path $t.Lab 'notice.log' | Should -Not -Exist
        # Past due: the host was off past the warning, and the undo is on its way.
        [IO.File]::WriteAllText((Join-Path $t.Root "state\runs\$a\timer-due"), "2000-01-01T00:05:00Z`n")
        (Invoke-TestWarn $t $a).Code | Should -Be 0
        Join-Path $t.Lab 'notice.log' | Should -Not -Exist
        # Kept: no timer.
        Write-TestFireIn $t $a 60
        (Invoke-TestRunCommand $t 'keep' $a).Code | Should -Be 0
        (Invoke-TestWarn $t $a).Code | Should -Be 0
        Join-Path $t.Lab 'notice.log' | Should -Not -Exist
    }

    It 'the hidden entry needs an Administrator and a well-formed run, root and config folder' {
        $a = Get-TestArmedRun $t
        Write-TestFireIn $t $a 60
        [IO.File]::WriteAllText((Join-Path $t.Lab 'NOT_ADMIN'), '')
        (Invoke-TestWarn $t $a).Code | Should -Be 20
        Remove-Item -LiteralPath (Join-Path $t.Lab 'NOT_ADMIN')
        (Invoke-TestLabCapture $t @('--warn', 'nonsense', $t.Root, $t.Etc, 'laby')).Code | Should -Be 40
        (Invoke-TestLabCapture $t @('--warn', $a, 'relative', $t.Etc, 'laby')).Code | Should -Be 40
        Join-Path $t.Lab 'notice.log' | Should -Not -Exist
    }

    It 'the warning is not an action: the help does not offer it' {
        $r = Invoke-TestLabCapture $t @('-h')
        $r.Out | Should -Not -Match '--warn'
    }
}
