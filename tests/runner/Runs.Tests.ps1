#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 runs, and naming a run by its last 4
# characters (docs\Conventions.md section 3.1). Mirrors runs.bats.

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
}

Describe 'labyrinth.ps1 runs' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'runs with no runs says so, exits 0 and creates nothing' {
        $r = Invoke-TestLabRun $t @('runs')
        $r.Code | Should -Be 0
        $r.Out | Should -BeExactly "no runs on this host ($(Join-Path $t.Root 'state\runs'))"
        $t.Root | Should -Not -Exist
    }

    It 'runs needs an Administrator' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        (Invoke-TestLabRun $t @('runs')).Code | Should -Be 20
    }

    It 'runs shows each state, oldest first, within 78 columns' {
        $a = Get-TestArmedRun $t
        $b = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('keep', $b)).Code | Should -Be 0
        $c = Get-TestArmedRun $t
        (Invoke-TestLabRun $t @('rollback', $c)).Code | Should -Be 0
        $r = Invoke-TestLabRun $t @('runs')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines[0] | Should -BeExactly 'RUN                   PHASE   START (UTC)      STATE'
        $lines[1] | Should -BeLike "$a observe * armed: rolls back at ??:?? UTC"
        $lines[2] | Should -BeLike "$b observe * kept"
        $lines[3] | Should -BeLike "$c observe * rolled back"
        $lines[1] | Should -BeLike ('* {0}-{1}-{2} {3}:{4} *' -f $a.Substring(0, 4), $a.Substring(4, 2), $a.Substring(6, 2), $a.Substring(9, 2), $a.Substring(11, 2))
        $r.Out | Should -Match ([regex]::Escape("like 'labyrinth.ps1 keep $(Get-TestSuffix $a)'"))
        ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 78
    }

    It 'an armed run shows when its timer was due, or that the time is unknown' {
        $a = Get-TestArmedRun $t
        $due = Join-Path $t.Root "state\runs\$a\timer-due"
        [IO.File]::WriteAllText($due, "2000-01-01T00:05:00Z`n")
        (Invoke-TestLabRun $t @('runs')).Out | Should -Match 'armed: was due 00:05 UTC'
        Remove-Item -LiteralPath $due
        (Invoke-TestLabRun $t @('runs')).Out | Should -Match 'armed: rollback time unknown'
    }

    It 'a run named by its last 4 characters, in any case, is kept' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('keep', (Get-TestSuffix $a).ToUpperInvariant())
        $r.Code | Should -Be 0
        $r.Out | Should -Match "using run $a"
        $r.Out | Should -Match "kept: the revert timer for run $a is cancelled"
    }

    It 'a suffix that matches no run, or more than one, is refused' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('rollback', 'beef')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "no run ending in 'beef'"
        $twin = Join-Path $t.Root "state\runs\20000101T000000Z-$(Get-TestSuffix $a)"
        Copy-Item -LiteralPath (Join-Path $t.Root "state\runs\$a") -Destination $twin -Recurse
        $r = Invoke-TestLabRun $t @('rollback', (Get-TestSuffix $a))
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'ends more than one run'
        [IO.File]::ReadAllText((Join-Path $t.Lab 'toggle.conf')) | Should -Match 'setting=on'
    }

    It 'keep without a run keeps the only armed run' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('keep')
        $r.Code | Should -Be 0
        $r.Out | Should -Match "kept: the revert timer for run $a is cancelled"
    }

    It 'keep without a run refuses when no run, or more than one, is armed' {
        $r = Invoke-TestLabRun $t @('keep')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'nothing to keep'
        $a = Get-TestArmedRun $t
        $b = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('keep')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "(?s)$a.*$b"
        $r.Err | Should -Match 'more than one run has an armed revert timer'
        Join-Path $t.Root "state\runs\$a\timer" | Should -Exist
        Join-Path $t.Root "state\runs\$b\timer" | Should -Exist
    }

    It 'rollback without a run lists the runs and changes nothing' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('rollback')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "(?s)$a.*needs a run ID"
        [IO.File]::ReadAllText((Join-Path $t.Lab 'toggle.conf')) | Should -Match 'setting=on'
        Join-Path $t.Root "state\runs\$a\timer" | Should -Exist
    }

    It 'a reference that is neither an ID nor 4 hex characters is a usage error' {
        (Invoke-TestLabRun $t @('keep', '4f2')).Code | Should -Be 40
        (Invoke-TestLabRun $t @('rollback', 'zzzz')).Code | Should -Be 40
        $t.Root | Should -Not -Exist
    }
}
