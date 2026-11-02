#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -Show ID: what one run changed, read from
# its manifest (docs\Conventions.md sections 3.1 and 7). Mirrors show.bats.

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

    # Assert-TestNarrow TEXT ROOT: every line is at most 78 columns, except a
    # line that names a path under the test folder (a path comes last and
    # may run over).
    function Assert-TestNarrow {
        param([string] $Text, [string] $Root)
        foreach ($l in ($Text -split '\r?\n')) {
            if ($l.Contains($Root)) { continue }
            $l.Length | Should -BeLessOrEqual 78 -Because $l
        }
    }
}

Describe 'labyrinth.ps1 -Show' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $parent = Split-Path -Parent $t.Root
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'lists a run''s header, its module and each change with its backup' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match "^Run $a\r?\n"
        $r.Out | Should -Match '(?m)^  Phase:     observe\r?$'
        $r.Out | Should -Match '(?m)^  Profile:   test\r?$'
        $r.Out | Should -Match '(?m)^  Host:      \S+\r?$'
        $r.Out | Should -Match '(?m)^  Group:     ring1\r?$'
        $r.Out | Should -Match '(?m)^  Started:   \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\r?$'
        $r.Out | Should -Match '(?m)^  Ended:     \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\r?$'
        $r.Out | Should -Match '(?m)^  State:     armed: undo at \d\d:\d\d UTC\r?$'
        $r.Out | Should -Match '(?m)^Module: Toggle setting sample \(observe\.toggle\)\r?\n  Status:    applied\r?\n  Change:    file_created '
        # The first run created the file: nothing to back up. A second run
        # changes a file that exists, and names its backup.
        (Invoke-TestRunCommand $t 'keep' $a).Code | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $lab 'toggle.conf'), "before`n")
        $r = Invoke-TestApply $t @('ring1', 'no')
        $r.Code | Should -Be 0
        $b = Get-TestRunId $r.Output
        $r = Invoke-TestLabRun $t @('-Show', $b)
        $r.Out | Should -Match '(?m)^  Change:    file '
        $r.Out | Should -Match '(?m)^  Backup:    .*-toggle\.conf\r?$'
        Assert-TestNarrow $r.Out $parent
    }

    It 'ends with the run log''s path, and names a run by its last 4 characters' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('-Show', $a.Substring($a.Length - 4))
        $r.Code | Should -Be 0
        $r.Out | Should -Match "using run $a"
        $log = Join-Path $t.Root "state\runs\$a\output.log"
        $log | Should -Exist
        @($r.Out -split '\r?\n')[-1] | Should -Be "Log: $log"
    }

    It 'for a run that was undone says so and still lists its changes' {
        $a = Get-TestArmedRun $t
        (Invoke-TestRunCommand $t 'rollback' $a).Code | Should -Be 0
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '(?m)^  State:     undone\r?$'
        $r.Out | Should -Match '(?m)^  Status:    undone\r?\n  Change:    file_created '
        Assert-TestNarrow $r.Out $parent
    }

    It 'for a run with a failed module says what failed and that it was undone' {
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 30
        $a = Get-TestRunId $r.Output
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '(?m)^Module: Toggle setting sample \(observe\.toggle\)\r?\n  Status:    failed \(verify exit 30\), then undone\r?$'
        $r.Out | Should -Match '(?m)^  Change:    file_created '
        Assert-TestNarrow $r.Out $parent
    }

    It 'for a module whose apply failed names the exit code' {
        New-Item -ItemType File -Path (Join-Path $lab 'FAIL_APPLY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 40
        $a = Get-TestRunId $r.Output
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Out | Should -Match '(?m)^  Status:    failed \(apply exit 40\), then undone\r?$'
    }

    It 'for a module kept once verified says so' {
        Write-TestProfile $t 'observe.keeper'
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 0
        $a = Get-TestRunId $r.Output
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Out | Should -Match '(?m)^  Status:    kept once verified\r?$'
    }

    It 'never prints a secret: not a new password, nor a file a module backed up' {
        Write-TestProfile $t 'observe.rotate'
        [IO.File]::WriteAllText((Join-Path $lab 'rotate.pw'), "old-secret-value`n")
        [IO.File]::WriteAllText((Join-Path $lab 'tty.in'), "recorded`n")
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $a = Get-TestRunId $r.Output
        $shown = [IO.File]::ReadAllText((Join-Path $lab 'tty.out'))
        $shown | Should -Match '(?m)^      ([A-Za-z0-9_.+=-]{20})\r?$'
        $pw = ([regex]::Match($shown, '(?m)^      ([A-Za-z0-9_.+=-]{20})\r?$')).Groups[1].Value
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Code | Should -Be 0
        $r.Out | Should -Match '(?m)^  Change:    file '
        $r.Out.Contains($pw) | Should -BeFalse
        $r.Out.Contains('old-secret-value') | Should -BeFalse
        Assert-TestNarrow $r.Out $parent
    }

    It 'changes nothing: not the manifest, not the log, not the data root' {
        $a = Get-TestArmedRun $t
        $snap = {
            Get-ChildItem -LiteralPath $t.Root -Recurse -File | Sort-Object FullName | ForEach-Object {
                '{0} {1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName).Hash
            }
        }
        $before = (& $snap) -join "`n"
        (Invoke-TestLabRun $t @('-Show', $a)).Code | Should -Be 0
        $after = (& $snap) -join "`n"
        $after | Should -Be $before
    }

    It 'with no runs asks for an ID and says there are none' {
        $r = Invoke-TestLabRun $t @('-Show')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape('-Show needs a run ID, or its last 4 characters'))
        $r.Err | Should -Match ([regex]::Escape('There are no runs on this host.'))
        $r.Out | Should -Be ''
        $t.Root | Should -Not -Exist
    }

    It 'without an ID lists the runs and shows none' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('-Show')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "(?s)$a.*-Show needs a run ID, or its last 4 characters"
        $r.Err | Should -Match ([regex]::Escape('Pick one from the list above.'))
        $r.Out | Should -Be ''
    }

    It 'needs an Administrator, and a run that does not exist points to -History' {
        $a = Get-TestArmedRun $t
        $r = Invoke-TestLabRun $t @('-Show', 'beef')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "no run ending in 'beef'"
        $r.Err | Should -Match '-History'
        New-Item -ItemType File -Path (Join-Path $lab 'NOT_ADMIN') | Out-Null
        $r = Invoke-TestLabRun $t @('-Show', $a)
        $r.Code | Should -Be 20
        $r.Err | Should -Match '-Show needs an elevated Administrator session'
    }

    It 'is refused with the options it does not use' {
        $r = Invoke-TestLabRun $t @('-Show', '4f2a', '-All')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'is only for -u, not -Show'
        (Invoke-TestLabRun $t @('-Show', '4f2a', '-y')).Code | Should -Be 40
        $r = Invoke-TestLabRun $t @('-Show', '4f2a', '-History')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'two actions on one line'
    }
}
