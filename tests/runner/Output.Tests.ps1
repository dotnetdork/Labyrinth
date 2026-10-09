#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 console output (docs\Conventions.md
# section 3.2): status words with plain names, labelled lines, the header,
# the end of a run, the recaps and the run log. Mirrors output.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Get-TestLine R: the output lines of a run, without blank lines, as
    # bats gives them, so that the two suites count lines alike.
    function Get-TestLine {
        param($R)
        return @($R.Output -split "`r?`n" | Where-Object { $_ -ne '' })
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

    # Get-TestLastLineOf R TEXT: the index of the last line containing TEXT, or -1.
    function Get-TestLastLineOf {
        param($R, [string] $Text)
        $lines = Get-TestLine $R
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i].Contains($Text)) { return $i }
        }
        return -1
    }

    # Write-TestEntry T MODULE ENTRY LINE...: replace an entry point of a
    # fixture module.
    function Write-TestEntry {
        param($T, [string] $Module, [string] $Entry, [string[]] $Line)
        Set-Content -LiteralPath (Join-Path $T.Lab "phases\observe\modules\$Module\$Entry.ps1") -Encoding Ascii -Value $Line
    }

    # The labels a detail line may start with (docs\Conventions.md section 3.2).
    $script:Labels = 'Found|Will do|Did|Why|Risk|Problem|Cause|Fix|Undo|Note|Log|Script|It said|Before|More'
}

Describe 'labyrinth.ps1 console output' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
    }

    It "plan starts each module's result with its status word, then its name and ID" {
        Write-TestProfile $t @('observe.clean', 'observe.sample', 'observe.blocked', 'observe.crash', 'observe.linuxonly', 'observe.badyml')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $lines = Get-TestLine $r
        ($lines -ccontains 'OK       Nothing-to-do sample (observe.clean)') | Should -BeTrue
        ($lines -ccontains 'CHANGE   No-op sample (observe.sample)') | Should -BeTrue
        ($lines -ccontains 'BLOCKED  Blocked sample (observe.blocked)') | Should -BeTrue
        ($lines -ccontains 'ERROR    Crashing sample (observe.crash)') | Should -BeTrue
        ($lines -ccontains 'WARN     Linux-only sample (observe.linuxonly)') | Should -BeTrue
        # A module.yml that does not load has no name to show.
        ($lines -ccontains 'ERROR    observe.badyml') | Should -BeTrue
    }

    It 'a module.yml error is a Found line under the ERROR line' {
        Write-TestProfile $t @('observe.badyml')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $lines = Get-TestLine $r
        $n = Get-TestLineOf $r 'ERROR    observe.badyml'
        $lines[$n + 1] | Should -BeExactly '  Problem:   invalid module.yml, so the module cannot be loaded'
        $lines[$n + 2] | Should -Match '^  Found: {5}module\.yml:\d+: unknown key color$'
    }

    It 'module output, both streams, is shown as Note lines under its result line' {
        Write-TestProfile $t @('observe.clean', 'observe.sample')
        Write-TestEntry $t 'clean' 'check' @("Write-Output 'on-stdout'", "[Console]::Error.WriteLine('on-stderr')", 'exit 0')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = Get-TestLine $r
        $n = Get-TestLineOf $r 'OK       Nothing-to-do sample (observe.clean)'
        $lines[$n + 1] | Should -BeExactly '  Note:      on-stdout'
        $lines[$n + 2] | Should -BeExactly '  Note:      on-stderr'
        $n = Get-TestLineOf $r 'CHANGE   No-op sample (observe.sample)'
        $lines[$n + 1] | Should -BeExactly '  Note:      sample: a change is needed'
        $r.Output | Should -Not -Match 'CLIXML|NativeCommandError|CategoryInfo'
    }

    It "a module's 'key: text' lines become labelled lines; others are Notes" {
        Write-TestProfile $t @('observe.sample')
        Write-TestEntry $t 'sample' 'check' @("'found: password logins are on'", "'Will do: turn them off'",
            "'  WHY: a stolen password stops working'", "'risk: none'", "'colour: blue'", "''", 'exit 10')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = Get-TestLine $r
        $n = Get-TestLineOf $r 'CHANGE   No-op sample (observe.sample)'
        $lines[$n + 1] | Should -BeExactly '  Found:     password logins are on'
        $lines[$n + 2] | Should -BeExactly '  Will do:   turn them off'
        $lines[$n + 3] | Should -BeExactly '  Why:       a stolen password stops working'
        $lines[$n + 4] | Should -BeExactly '  Risk:      none'
        $lines[$n + 5] | Should -BeExactly '  Note:      colour: blue'
        # The module gave a Risk line, so the runner adds none of its own.
        @($lines | Where-Object { $_ -like '  Risk:*' }).Count | Should -Be 1
    }

    It 'a CHANGE without a Risk line gets the risk in plain words' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestPlan $t
        ((Get-TestLine $r) -ccontains '  Risk:      changes this host; each change is saved first and can be undone') | Should -BeTrue
    }

    It "a failed entry point without a 'problem:' line gets the runner's Problem, Script and It said" {
        Write-TestProfile $t @('observe.crash')
        Write-TestEntry $t 'crash' 'check' @('1..12 | ForEach-Object { "line $_" }', 'exit 3')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $lines = Get-TestLine $r
        ($lines -ccontains '  Problem:   its check script failed with exit code 3 and gave no reason') | Should -BeTrue
        ($lines -ccontains "  Script:    $(Join-Path $t.Lab 'phases\observe\modules\crash\check.ps1')") | Should -BeTrue
        # Only the last 10 lines.
        @($lines | Where-Object { $_ -like '  It said:   line *' }).Count | Should -Be 10
        ($lines -ccontains '  It said:   line 3') | Should -BeTrue
        ($lines -ccontains '  It said:   line 2') | Should -BeFalse
        @($lines | Where-Object { $_ -like '  *' })[-1] | Should -BeExactly "  More:      $($t.Self) help observe.crash"
    }

    It "a failed entry point that ends with 'problem:' is shown as it said it" {
        Write-TestProfile $t @('observe.crash')
        Write-TestEntry $t 'crash' 'check' @("'found: no firewall tool'", "'problem: Windows Defender Firewall is off'", 'exit 40')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $lines = Get-TestLine $r
        ($lines -ccontains '  Found:     no firewall tool') | Should -BeTrue
        ($lines -ccontains '  Problem:   Windows Defender Firewall is off') | Should -BeTrue
        $r.Output | Should -Not -Match 'gave no reason|It said:'
    }

    It 'every detail line starts with a label, and every WARN, BLOCKED or ERROR block ends with More' {
        Write-TestProfile $t @('observe.clean', 'observe.sample', 'observe.blocked', 'observe.crash', 'observe.linuxonly', 'observe.manual', 'observe.toggle')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $word = ''
        $prev = ''
        foreach ($l in (Get-TestLine $r)) {
            if ($l.StartsWith('  ')) {
                $l | Should -Match "^  ($script:Labels): +\S"
            } else {
                # A block ends at the next line that is not a detail line.
                if ($word -cmatch '^(WARN|BLOCKED|ERROR)$') {
                    $prev | Should -BeLike "  More:      $([Management.Automation.WildcardPattern]::Escape($t.Self)) help observe.*" -Because "a $word block"
                }
                $word = ($l -split ' ')[0]
            }
            $prev = $l
        }
    }

    It 'plan says it changes nothing, then names the host and how many modules it checks' {
        Write-TestProfile $t @('observe.clean', 'observe.sample')
        $lines = Get-TestLine (Invoke-TestPlan $t)
        $hostName = $script:ThisHost
        $lines[2] | Should -BeExactly "This is a plan: Labyrinth only looks, and nothing on $hostName changes."
        $lines[3] | Should -BeExactly "Host $hostName is in group ring1."
        $lines[4] | Should -BeExactly 'Checking 2 modules of profile test, most urgent first.'
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
        Write-TestHost $t 'ring1'
        Write-TestProfile $t @('observe.clean', 'observe.sample')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = Get-TestLine $r
        $last = $lines.Count - 1
        $lines[$last - 4] | Should -BeExactly 'Summary: 2 modules: 1 OK, 1 CHANGE.'
        $lines[$last - 3] | Should -BeExactly 'Nothing on this host was changed.'
        # Too long for one line with the test's paths, so the command has its own.
        $lines[$last - 2] | Should -BeExactly 'Next:'
        $lines[$last - 1] | Should -BeExactly "  $($t.Self) apply observe -Profile test -Root $($t.Root) -Config $($t.Etc)"
        $lines[$last] | Should -BeExactly 'plan finished: exit 10 (change needed)'
    }

    It "plan's Next line never names an apply that would be refused" {
        Write-TestProfile $t @('observe.sample')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $r.Output | Should -Match ([regex]::Escape('Next: list this host in the hosts file, with its group and profile;'))
        $r.Output | Should -Not -Match 'labyrinth\.ps1 apply observe'
        Write-TestHost $t 'ring1'
        $hostsFile = Join-Path $t.Etc 'hosts'
        [IO.File]::WriteAllText($hostsFile, [IO.File]::ReadAllText($hostsFile).Replace(' test windows', ' other windows'))
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $r.Output | Should -Match ([regex]::Escape("Next: apply uses this host's profile in the hosts file, other."))
        $r.Output | Should -Not -Match 'labyrinth\.ps1 apply observe'
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

    It 'plan shows a manual-only module as WARN and counts it as WARN' {
        Write-TestProfile $t @('observe.clean', 'observe.manual')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $lines = Get-TestLine $r
        ($lines -ccontains 'WARN     Manual steps sample (observe.manual)') | Should -BeTrue
        ($lines -ccontains '  Found:     this needs a person; Labyrinth will not change it') | Should -BeTrue
        $r.Output | Should -Match ([regex]::Escape('Summary: 2 modules: 1 OK, 1 WARN.'))
        ($r.Output -cnotmatch 'CHANGE') | Should -BeTrue
    }

    It 'apply: a two-line header, a CHANGE line before each change and OK after it' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 0
        $lines = Get-TestLine $r
        $lines[0] | Should -Match '^labyrinth \S+: APPLY observe, profile test$'
        $lines[1] | Should -Match '^run \d{8}T\d{6}Z-[0-9a-f]{4} on host .+, group ring1$'
        $lines[2] | Should -BeExactly 'First Labyrinth plans; nothing changes until you confirm.'
        # The plan's CHANGE line comes first; the last one starts the change.
        $a = Get-TestLastLineOf $r 'CHANGE   Toggle setting sample (observe.toggle)'
        $b = Get-TestLineOf $r 'OK       Toggle setting sample (observe.toggle)'
        $a | Should -BeGreaterThan (Get-TestLineOf $r 'Type the group name')
        $b | Should -BeGreaterThan $a
        $lines[$b + 1] | Should -BeExactly '  Did:       applied and verified'
        $r.Output | Should -Match ([regex]::Escape('Summary: 1 module: 1 OK.'))
        $r.Output | Should -Not -Match 'Next:'
        $lines[-1] | Should -BeExactly 'apply finished: exit 0 (done)'
    }

    It 'apply: a failed verify is FAIL, the module is rolled back and the run stops' {
        Write-TestProfile $t @('observe.toggle')
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 30
        $id = Get-TestRunId $r.Output
        $lines = Get-TestLine $r
        $n = Get-TestLineOf $r 'FAIL     Toggle setting sample (observe.toggle)'
        $lines[$n + 1] | Should -BeExactly '  Problem:   its verify script failed with exit code 30 and gave no reason'
        $lines[$n + 2] | Should -BeExactly "  Script:    $(Join-Path $t.Lab 'phases\observe\modules\toggle\verify.ps1')"
        ($lines -ccontains '  Did:       rolled back') | Should -BeTrue
        ($lines -ccontains "  Log:       $(Join-Path $t.Root "state\runs\$id\output.log")") | Should -BeTrue
        ($lines -ccontains "  More:      $($t.Self) help observe.toggle") | Should -BeTrue
        $r.Output | Should -Match ([regex]::Escape('Summary: 1 module: 1 FAIL.'))
        $r.Output | Should -Match ([regex]::Escape('Next: undo the earlier changes, or keep them, with the commands above.'))
        $r.Output | Should -Match ([regex]::Escape('apply finished: exit 30 (a check failed and that change was undone; earlier ones stay)'))
    }

    It 'apply: the recap comes after break-glass and before the group prompt' {
        Write-TestProfile $t @('observe.toggle', 'observe.blocked', 'observe.manual')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $a = Get-TestLineOf $r 'Break-glass account labadmin: confirmed and recorded.'
        $b = Get-TestLineOf $r 'About to apply on host'
        $c = Get-TestLineOf $r 'Type the group name (ring1)'
        $a | Should -BeGreaterThan -1
        $b | Should -BeGreaterThan $a
        ($c -ge $b) | Should -BeTrue
        $lines = Get-TestLine $r
        ($lines -ccontains '  Will change: Toggle setting sample (observe.toggle)') | Should -BeTrue
        ($lines -ccontains '  Blocked:     Blocked sample (observe.blocked)') | Should -BeTrue
        ($lines -ccontains '  Manual:      Manual steps sample (observe.manual)') | Should -BeTrue
        $lines[$c - 1] | Should -BeExactly 'To go ahead, type the group name. Anything else stops here; nothing changes.'
        $r.Output | Should -Not -Match 'connected over SSH'
    }

    It 'apply: over SSH, the recap warns when a change may interrupt a service' {
        $yml = Join-Path $t.Lab 'phases\observe\modules\toggle\module.yml'
        Set-Content -LiteralPath $yml -Encoding Ascii -Value @(Get-Content -LiteralPath $yml | ForEach-Object {
                if ($_ -like 'risk:*') { 'risk: service-affecting' } else { $_ } })
        Write-TestProfile $t @('observe.toggle')
        $env:SSH_CONNECTION = '192.0.2.9 50000 192.0.2.1 22'
        try { $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep') } finally { Remove-Item Env:\SSH_CONNECTION }
        $r.Code | Should -Be 0
        $a = Get-TestLineOf $r 'You are connected over SSH, and a change may interrupt a service.'
        $a | Should -BeGreaterThan -1
        $a | Should -BeLessThan (Get-TestLineOf $r 'Type the group name')
        $r.Output | Should -Match 'Keep a second session open until you have checked you can log in\.'
    }

    It 'apply: before the keep prompt, the time the revert timer rolls the run back' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $due = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$id\timer-due")).Trim()
        $a = Get-TestLineOf $r "The revert timer rolls this run back at $($due.Substring(11, 5)) UTC, "
        $b = Get-TestLineOf $r 'Type keep to keep'
        $a | Should -BeGreaterThan -1
        ($b -ge $a) | Should -BeTrue
        $r.Output | Should -Match ([regex]::Escape("Next: check you can log in from a NEW session, then '$($t.Self) keep $($id.Substring($id.Length - 4))'."))
    }

    It 'output lines are at most 78 columns, unless they end with a path' {
        Write-TestProfile $t @('observe.clean', 'observe.sample', 'observe.manual', 'observe.blocked', 'observe.crash', 'observe.toggle')
        foreach ($l in (Get-TestLine (Invoke-TestPlan $t))) {
            if ($l.Length -gt 78) { ($l -split ' ')[-1] | Should -Match '^[A-Za-z]:\\' -Because $l }
        }
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_VERIFY') | Out-Null
        Write-TestProfile $t @('observe.toggle', 'observe.manual', 'observe.blocked')
        # The prompts end without a newline, so they are answered by options here.
        foreach ($l in (Get-TestLine (Invoke-TestApply $t @() @('-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1')))) {
            if ($l.Length -gt 78) { ($l -split ' ')[-1] | Should -Match '^[A-Za-z]:\\' -Because $l }
        }
    }

    It 'apply writes the run log, readable by administrators only, with every module line' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $log = Join-Path $t.Root "state\runs\$id\output.log"
        # Users, Authenticated Users and Everyone get no access to it.
        $sids = @((Get-Acl -LiteralPath $log).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                ForEach-Object { $_.IdentityReference.Value })
        $sids | Should -Not -Contain 'S-1-5-32-545'
        $sids | Should -Not -Contain 'S-1-5-11'
        $sids | Should -Not -Contain 'S-1-1-0'
        $text = @([IO.File]::ReadAllLines($log))
        $text[0] | Should -Match "labyrinth \S+: apply observe, run $id"
        ($text -ccontains 'observe.toggle check| toggle: setting is not on') | Should -BeTrue
        ($text -ccontains 'observe.toggle apply| toggle: setting=on') | Should -BeTrue
        @($text | Where-Object { $_ -cmatch '^\d{2}:\d{2}:\d{2} observe\.toggle verify exited 0$' }).Count | Should -Be 1
        ($text -ccontains 'OK       Toggle setting sample (observe.toggle)') | Should -BeTrue
        ($text -ccontains 'Type the group name (ring1) to apply this plan: ring1') | Should -BeTrue
        ($text -ccontains "kept: the revert timer for run $id is cancelled") | Should -BeTrue
        $r.Output | Should -Match ([regex]::Escape("Log: $log"))
    }

    It 'the run log keeps at most 500 lines from one entry point' {
        Write-TestProfile $t @('observe.toggle')
        $file = Join-Path $t.Lab 'phases\observe\modules\toggle\apply.ps1'
        $body = @(Get-Content -LiteralPath $file)
        Set-Content -LiteralPath $file -Encoding Ascii -Value (@($body[0..($body.Count - 2)]) + @('1..600 | ForEach-Object { "out $_" }', 'exit 0'))
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $text = @([IO.File]::ReadAllLines((Join-Path $t.Root "state\runs\$id\output.log")))
        @($text | Where-Object { $_.StartsWith('observe.toggle apply| ') }).Count | Should -Be 500
        ($text -ccontains 'observe.toggle apply: 101 more lines not logged') | Should -BeTrue
    }

    It "plan and a stopped apply: plan writes no log; the stopped run is marked for 'runs'" {
        Write-TestProfile $t @('observe.toggle')
        [void](Invoke-TestPlan $t)
        $t.Root | Should -Not -Exist
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1')
        $r.Code | Should -Be 30
        $id = Get-TestRunId $r.Output
        Join-Path $t.Root "state\runs\$id\problems" | Should -Exist
        $k = Invoke-TestLab $t @('runs', '-Root', $t.Root, '-Config', $t.Etc)
        $k.Code | Should -Be 0
        ((Get-TestLine $k) -ccontains "  $($id.Substring($id.Length - 4))  $(Join-Path $t.Root "state\runs\$id\output.log")") | Should -BeTrue
    }

    It 'a rollback by the revert timer adds to the run log' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $id = Get-TestRunId $r.Output
        # The stored timer command, as Task Scheduler would run it.
        $line = [IO.File]::ReadAllText((Join-Path $t.Root "state\runs\$id\timer")).TrimEnd()
        $psi = New-Object Diagnostics.ProcessStartInfo($script:HostExe, $line.Substring($script:HostExe.Length + 1))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync()
        [void]$p.StandardOutput.ReadToEnd()
        [void]$err.Result
        $p.WaitForExit()
        $p.ExitCode | Should -Be 0
        $text = @([IO.File]::ReadAllLines((Join-Path $t.Root "state\runs\$id\output.log")))
        @($text | Where-Object { $_ -match "labyrinth \S+: rollback run $id" }).Count | Should -BeGreaterThan 0
        ($text -ccontains '  Did:       rolled back') | Should -BeTrue
        ($text -ccontains 'rollback finished: exit 0 (rolled back)') | Should -BeTrue
    }

    It 'probe: a header, a status line per service, Summary, Next and finished' {
        Write-TestConfig $t 'services' @('web http web.test 80 -', 'mail smtp mail.test 25 -')
        $r = Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $lines = Get-TestLine $r
        $lines[0] | Should -Match '^labyrinth [^ ]+: probe the scored services$'
        $lines[1] | Should -BeExactly 'OK       [web] pass: fake probe'
        $lines[3] | Should -BeExactly 'Summary: 2 OK'
        $lines[4] | Should -BeExactly 'probe finished: exit 0 (no service failed)'
        [IO.File]::WriteAllText((Join-Path $t.Lab 'probe-state'), "web.test fail`nmail.test fail`n")
        $r = Invoke-TestLab $t @('probe', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 30
        $lines = Get-TestLine $r
        $lines[1] | Should -BeExactly 'FAIL     [web] fail: fake probe'
        $lines[3] | Should -BeExactly 'Summary: 2 FAIL'
        $lines[4] | Should -BeExactly "Next: bring the failed services back, then run '$($t.Self) probe' again."
        $lines[5] | Should -BeExactly 'probe finished: exit 30 (2 services failed)'
    }

    It 'the Next line after several errors says errors' {
        Write-TestProfile $t @('observe.crash', 'observe.badyml')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'Next: fix the errors above, then run the same command again\.'
        Write-TestProfile $t @('observe.crash')
        $r = Invoke-TestPlan $t
        $r.Output | Should -Match 'Next: fix the error above, then run the same command again\.'
    }

    It 'a phase with no modules in the profile is a WARN naming the phase' {
        Write-TestProfile $t @()
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 0
        $lines = Get-TestLine $r
        ($lines -ccontains 'WARN     Phase observe') | Should -BeTrue
        ($lines -ccontains '  Found:     profile test lists no observe modules: nothing to check') | Should -BeTrue
    }

    It 'rollback ends with the exit code and its meaning' {
        Write-TestProfile $t @('observe.toggle')
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $id = Get-TestRunId $r.Output
        $k = Invoke-TestRunCommand $t 'rollback' $id
        $k.Code | Should -Be 0
        $lines = Get-TestLine $k
        $lines[0] | Should -Match "^labyrinth \S+: rollback run $id$"
        ($lines -ccontains 'OK       Toggle setting sample (observe.toggle)') | Should -BeTrue
        $lines[-3] | Should -BeExactly 'Summary: 1 module: 1 OK.'
        $lines[-2] | Should -BeExactly "Log: $(Join-Path $t.Root "state\runs\$id\output.log")"
        $lines[-1] | Should -BeExactly 'rollback finished: exit 0 (rolled back)'
    }
}
