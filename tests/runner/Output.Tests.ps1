#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 console output (docs\Conventions.md
# section 3.2): status words, indented module output, the two-line header,
# the end of a run and the recaps. Mirrors output.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Get-TestLine R: the output lines of a run.
    function Get-TestLine {
        param($R)
        return @($R.Output -split "`r?`n")
    }

    # Get-TestLineOf R TEXT: the index of the first line containing TEXT, or -1.
    function Get-TestLineOf {
        param($R, [string] $Text)
        $lines = Get-TestLine $R
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($Text)) { return $i }
        }
        return -1
    }
}

Describe 'labyrinth.ps1 console output' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
    }

    It "plan starts each module's result with its status word, padded to 9 characters" {
        Write-TestProfile $t @('observe.clean', 'observe.sample', 'observe.blocked', 'observe.crash', 'observe.linuxonly', 'observe.badyml')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $lines = Get-TestLine $r
        ($lines -ccontains 'OK       [observe.clean] check: nothing to do') | Should -BeTrue
        ($lines -ccontains 'CHANGE   [observe.sample] check: change needed; plan follows') | Should -BeTrue
        ($lines -ccontains 'BLOCKED  [observe.blocked] check: blocked by a safety gate') | Should -BeTrue
        ($lines -ccontains 'ERROR    [observe.crash] check: error (exit 3)') | Should -BeTrue
        ($lines -ccontains 'WARN     [observe.linuxonly] skipped: no Windows entry points') | Should -BeTrue
        ($lines -ccontains 'ERROR    [observe.badyml] error: invalid module.yml') | Should -BeTrue
    }

    It 'a module.yml error is printed indented under its ERROR line' {
        Write-TestProfile $t @('observe.badyml')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $n = Get-TestLineOf $r '[observe.badyml] error: invalid module.yml'
        (Get-TestLine $r)[$n + 1] | Should -Match '^ {11}\S.*unknown key color$'
    }

    It 'module output, both streams, is indented 11 spaces under its result line' {
        Write-TestProfile $t @('observe.clean', 'observe.sample')
        Set-Content -LiteralPath (Join-Path $t.Lab 'phases\observe\modules\clean\check.ps1') -Encoding Ascii -Value @(
            "Write-Output 'on-stdout'"
            "[Console]::Error.WriteLine('on-stderr')"
            'exit 0'
        )
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = Get-TestLine $r
        $n = Get-TestLineOf $r '[observe.clean] check: nothing to do'
        $lines[$n + 1] | Should -Be '           on-stdout'
        $lines[$n + 2] | Should -Be '           on-stderr'
        $n = Get-TestLineOf $r '[observe.sample] check: change needed'
        $lines[$n + 1] | Should -Be '           sample: a change is needed'
        $r.Output | Should -Not -Match 'CLIXML|NativeCommandError|CategoryInfo'
    }

    It 'the plan header is two lines that say nothing is recorded' {
        Write-TestProfile $t @('observe.sample')
        $lines = Get-TestLine (Invoke-TestPlan $t)
        $lines[0] | Should -Match '^labyrinth \S+: plan observe, profile test$'
        $lines[1] | Should -Match '^run \d{8}T\d{6}Z-[0-9a-f]{4} \(plan mode: nothing is recorded\)$'
        $lines[0].Length | Should -BeLessOrEqual 78
        $lines[1].Length | Should -BeLessOrEqual 78
        $t.Root | Should -Not -Exist
    }

    It 'plan ends with Summary, Next and the exit code with its meaning' {
        Write-TestProfile $t @('observe.clean', 'observe.sample')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = @(Get-TestLine $r | Where-Object { $_ -ne '' })
        $last = $lines.Count - 1
        $lines[$last - 2] | Should -Be 'Summary: 1 OK, 1 CHANGE'
        $lines[$last - 1] | Should -Be "Next: labyrinth.ps1 apply observe -Profile test -Root $($t.Root) -Config $($t.Etc)"
        $lines[$last] | Should -Be 'plan finished: exit 10 (change needed)'
    }

    It 'the Next line fits what plan found' {
        Write-TestProfile $t @('observe.clean')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'Next:'
        $r.Output | Should -Match ([regex]::Escape('plan finished: exit 0 (nothing to do)'))
        Write-TestProfile $t @('observe.blocked')
        $r = Invoke-TestPlan $t
        $r.Output | Should -Match 'Next: clear what blocked it above'
        $r.Output | Should -Match ([regex]::Escape('plan finished: exit 20 (blocked)'))
        Write-TestProfile $t @('observe.manual')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $r.Output | Should -Match ([regex]::Escape('Next: a person carries out the manual steps above; apply changes nothing.'))
    }

    It 'apply: a two-line header, a CHANGE line before each change and OK after it' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 0
        $lines = Get-TestLine $r
        $lines[0] | Should -Match '^labyrinth \S+: APPLY observe, profile test$'
        $lines[1] | Should -Match '^run \d{8}T\d{6}Z-[0-9a-f]{4} on host .+, group ring1$'
        $a = Get-TestLineOf $r 'CHANGE   [observe.toggle] applying'
        $b = Get-TestLineOf $r 'OK       [observe.toggle] applied and verified'
        $a | Should -BeGreaterThan -1
        $b | Should -BeGreaterThan $a
        $r.Output | Should -Match 'Summary: 1 OK'
        $r.Output | Should -Not -Match 'Next:'
        @($lines | Where-Object { $_ -ne '' })[-1] | Should -Be 'apply finished: exit 0 (done)'
    }

    It 'apply: a failed verify is FAIL, the module is rolled back and the run stops' {
        Write-TestProfile $t @('observe.toggle')
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 30
        $lines = Get-TestLine $r
        ($lines -ccontains 'FAIL     [observe.toggle] verify failed (exit 30); rolling back') | Should -BeTrue
        ($lines -ccontains 'OK       [observe.toggle] rolled back') | Should -BeTrue
        $r.Output | Should -Match 'Summary: 1 FAIL'
        $r.Output | Should -Match 'Next: keep the earlier changes or undo them'
        $r.Output | Should -Match ([regex]::Escape('apply finished: exit 30 (a check failed, and that change was undone)'))
    }

    It 'apply: the recap comes after break-glass and before the group prompt' {
        Write-TestProfile $t @('observe.toggle', 'observe.blocked', 'observe.manual')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $a = Get-TestLineOf $r 'break-glass: labadmin confirmed'
        $b = Get-TestLineOf $r 'About to apply on host'
        $c = Get-TestLineOf $r 'Type the group name (ring1)'
        $a | Should -BeGreaterThan -1
        $b | Should -BeGreaterThan $a
        ($c -ge $b) | Should -BeTrue
        $lines = Get-TestLine $r
        ($lines -ccontains '  will change  observe.toggle') | Should -BeTrue
        ($lines -ccontains '  blocked      observe.blocked') | Should -BeTrue
        ($lines -ccontains '  manual       observe.manual') | Should -BeTrue
    }

    It 'apply: before the keep prompt, the time the revert timer rolls the run back' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $due = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$id\timer-due")).Trim()
        $a = Get-TestLineOf $r "The revert timer rolls this run back at $($due.Substring(11, 5)) UTC."
        $b = Get-TestLineOf $r 'Type keep to keep'
        $a | Should -BeGreaterThan -1
        ($b -ge $a) | Should -BeTrue
        $r.Output | Should -Match ([regex]::Escape("then 'labyrinth.ps1 keep $($id.Substring($id.Length - 4))'."))
    }

    It 'fixed output lines are at most 78 columns' {
        Write-TestProfile $t @('observe.clean', 'observe.sample', 'observe.manual')
        foreach ($l in (Get-TestLine (Invoke-TestPlan $t))) {
            if ($l.StartsWith('           ') -or $l.StartsWith('Next:')) { continue }
            $l.Length | Should -BeLessOrEqual 78 -Because $l
        }
    }
}
