#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -Doctor: a read-only check that this host
# is ready for a run (docs\Conventions.md section 3.1). One line per check,
# OK, WARN or FAIL, and a Fix line under a WARN or FAIL; any FAIL exits 20
# with a Next line for the first one. The host-specific parts are test
# doubles (tests\fixtures\Doubles.ps1): NOT_ADMIN, UNTRUSTED, NO_TIMER,
# NO_TIMESYNC, TIMESYNC_UNKNOWN and a CLOCK file. Mirrors doctor.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Write-TestRelease T: write release.sha256 for the test copy, as at release
    # time. Call it again after changing a file of the copy.
    function Write-TestRelease {
        param($T)
        $null = & (Join-Path $script:Repo 'tools\release\manifest.ps1') $T.Lab
    }

    # Invoke-TestDoctor T [EXTRA]: -Doctor with the test data root.
    function Invoke-TestDoctor {
        param($T, [string[]] $Extra = @())
        Invoke-TestLabCapture $T (@('-Doctor') + $Extra + @('-Root', $T.Root, '-Config', $T.Etc))
    }

    # Get-TestRow R: the check lines of the output.
    function Get-TestRow {
        param($R)
        return @($R.Out -split "`r?`n" | Where-Object { $_ -cmatch '^(OK|WARN|FAIL) ' })
    }

    # Get-TestFix R N: the Fix text under check line N.
    function Get-TestFix {
        param($R, [int] $N)
        $lines = @($R.Out -split "`r?`n")
        $rows = @(Get-TestRow $R)
        $at = [array]::IndexOf($lines, $rows[$N])
        $lines[$at + 1] | Should -BeLike '      Fix: *' -Because "row $N has no Fix line"
        return $lines[$at + 1].Substring(11)
    }

    # Assert-TestOnlyFail R N TEXT [WORD6]: check line N is the only FAIL and
    # holds TEXT, every other line is OK (line 6, the tools, is WORD6 when the
    # host's profile is not known), and Next repeats the fix under line N.
    function Assert-TestOnlyFail {
        param($R, [int] $N, [string] $Text, [string] $Word6 = 'OK')
        $R.Code | Should -Be 20 -Because $R.Out
        $rows = @(Get-TestRow $R)
        $rows.Count | Should -Be 8 -Because $R.Out
        for ($i = 0; $i -lt 8; $i++) {
            $word = 'OK'
            if ($i -eq $N) { $word = 'FAIL' }
            if ($i -eq 6 -and $N -ne 6) { $word = $Word6 }
            $rows[$i] | Should -BeLike ($word.PadRight(6) + '*') -Because "row ${i}: $($rows[$i])"
        }
        $rows[$N].Contains($Text) | Should -BeTrue -Because $rows[$N]
        $fix = Get-TestFix $R $N
        @($R.Out -split "`r?`n" | Where-Object { $_ -like 'Next: *' }) | Should -Be @("Next: $fix")
    }

    # Get-TestSnapshot T: every path of the test trees with its size and
    # time, then every file's hash: equal before and after means nothing
    # was written.
    function Get-TestSnapshot {
        param($T)
        $items = @(Get-ChildItem -LiteralPath $T.Lab, $T.Root, $T.Etc -Recurse -Force |
                Sort-Object FullName)
        # A folder's own time is left out: the system may touch it without a write.
        $rows = @($items | ForEach-Object { if ($_.PSIsContainer) { $_.FullName } else { '{0} {1} {2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } })
        $hashes = @($items | Where-Object { -not $_.PSIsContainer } |
                ForEach-Object { '{0} {1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        return ($rows + $hashes) -join "`n"
    }

    # Get-TestArmedRun T: apply, leave the revert timer armed, and return the
    # run ID.
    function Get-TestArmedRun {
        param($T)
        Remove-Item -LiteralPath (Join-Path $T.Lab 'toggle.conf') -ErrorAction SilentlyContinue
        $r = Invoke-TestApply $T @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        return Get-TestRunId $r.Output
    }

    # Add-TestModuleLine T MODULE LINE: add a line to a module's module.yml.
    function Add-TestModuleLine {
        param($T, [string] $Module, [string] $Line)
        Add-Content -LiteralPath (Join-Path $T.Lab "phases\observe\modules\$Module\module.yml") -Value "`n$Line" -Encoding Ascii
    }

    # Write-TestPastDue T RUN: make the run's revert timer overdue.
    function Write-TestPastDue {
        param($T, [string] $RunId)
        [IO.File]::WriteAllText((Join-Path $T.Root "state\runs\$RunId\timer-due"), "2000-01-01T00:05:00Z`n")
    }
}

Describe 'labyrinth.ps1 -Doctor' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        Write-TestConfig $t 'services' @('web http 127.0.0.1 80 -')
        Write-TestRelease $t
    }

    It 'a clean host passes every check, ends with Ready for a run., and exits 0' {
        $r = Invoke-TestDoctor $t
        $r.Code | Should -Be 0 -Because $r.Out
        $lines = @($r.Out -split "`r?`n")
        $lines[0] | Should -BeExactly 'OK    release matches release.sha256'
        $lines[1] | Should -BeExactly 'OK    code and data folders writable only by Administrators'
        $lines[2] | Should -BeExactly 'OK    configuration files read and filled in'
        $lines[3] | Should -BeExactly "OK    this host is $script:ThisHost in hosts, profile test"
        $lines[4] | Should -BeExactly 'OK    revert timer can be armed (Task Scheduler)'
        $lines[5] | Should -BeExactly 'OK    clock is set and time sync is running (fake-timesync)'
        $lines[6] | Should -BeExactly 'OK    tools for the test profile: present'
        $lines[7] | Should -BeExactly 'OK    no stale revert timer'
        $lines[8] | Should -BeExactly ''
        $lines[9] | Should -BeExactly 'Ready for a run.'
        $lines.Count | Should -Be 10
        $r.Err | Should -BeNullOrEmpty
    }

    It 'works without a data root: it makes none' {
        $r = Invoke-TestDoctor $t
        $r.Code | Should -Be 0
        Test-Path -LiteralPath $t.Root | Should -BeFalse
    }

    Context 'the release' {
        It 'a changed core file is the one FAIL, nothing else runs, and Next names the fix' {
            Add-Content -LiteralPath (Join-Path $t.Lab 'core\Log\Log.ps1') -Value '# changed'
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 20
            $lines = @($r.Out -split "`r?`n")
            $lines[0] | Should -BeExactly 'FAIL  release: core/log/Log.ps1 differs from the release'
            $lines[1] | Should -BeLike '      Fix: Copy Labyrinth here again*'
            $lines[2] | Should -BeExactly '      The other checks were not run.'
            $lines[3] | Should -BeExactly ''
            $lines[4] | Should -BeExactly ('Next: ' + $lines[1].Substring(11))
            $lines.Count | Should -Be 5
        }

        It 'a file planted in a module folder is a FAIL too' {
            [IO.File]::WriteAllText((Join-Path $t.Lab 'phases\observe\modules\toggle\extra.ps1'), "x`n")
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 20
            @($r.Out -split "`r?`n")[0] | Should -BeExactly 'FAIL  release: phases/observe/modules/toggle/extra.ps1 is not in the release'
        }

        It 'help still refuses a changed release, as it does for every command' {
            Add-Content -LiteralPath (Join-Path $t.Lab 'core\Log\Log.ps1') -Value '# changed'
            $r = Invoke-TestLabCapture $t @('-Doctor', '-h')
            $r.Code | Should -Be 20
            $r.Err | Should -Match 'will not run'
            $r.Out | Should -Not -Match 'FAIL'
        }

        It 'with no release.sha256 it is a WARN, which does not fail the check' {
            Remove-Item -LiteralPath (Join-Path $t.Lab 'release.sha256')
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            $lines = @($r.Out -split "`r?`n")
            $lines[0] | Should -BeExactly "WARN  no release.sha256: Labyrinth's files were not checked"
            $lines[1] | Should -BeLike '      Fix: *'
            $lines[-1] | Should -BeExactly 'Ready for a run.'
            $r.Out | Should -Not -Match 'FAIL'
        }
    }

    Context 'who can change the folders' {
        It 'a folder another account can change is the one FAIL' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'UNTRUSTED') | Out-Null
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 1 'can be changed by an account other than Administrators'
            (Get-TestRow $r)[1] | Should -BeExactly "FAIL  $($t.Lab) can be changed by an account other than Administrators"
        }
    }

    Context 'the configuration files' {
        It 'a missing services file is the one FAIL' {
            Remove-Item -LiteralPath (Join-Path $t.Etc 'services')
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 2 'services: missing'
            Get-TestFix $r 2 | Should -BeExactly "copy the team's services to $(Join-Path $t.Etc 'services')"
        }

        It 'a malformed line names the file and the line' {
            Write-TestConfig $t 'services' @('web http 127.0.0.1 80 -', 'web2 http 127.0.0.1')
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 2 'services: line 2: expected: name proto host[/path] port expect'
            Get-TestFix $r 2 | Should -BeExactly "edit $(Join-Path $t.Etc 'services')"
        }

        It 'an empty protected-accounts file is a FAIL' {
            Write-TestConfig $t 'protected-accounts' @()
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'protected-accounts: lists nothing'
        }

        It 'a missing protected-accounts file is a FAIL' {
            Remove-Item -LiteralPath (Join-Path $t.Etc 'protected-accounts')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'protected-accounts: missing'
        }

        It 'a value still copied from a template is a FAIL' {
            Write-TestConfig $t 'services' @('web http www.example.test 80 -')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'services: line 1: www.example.test is an example value'
            Write-TestConfig $t 'services' @('web http 127.0.0.1 80 -')
            Write-TestConfig $t 'event.conf' @('SIEM_ADDRESS=192.0.2.10')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'event.conf: SIEM_ADDRESS is an example value'
            Remove-Item -LiteralPath (Join-Path $t.Etc 'event.conf')
            Write-TestConfig $t 'never-ban' @('10.1.1.1', '198.51.100.0/28')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'never-ban: line 2: 198.51.100.0/28 is an example value'
        }

        It 'a setting out of range is a FAIL' {
            Write-TestConfig $t 'event.conf' @('REVERT_MINUTES=99')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'event.conf: REVERT_MINUTES must be a whole number from 1 to 60'
        }

        It 'a malformed optional file is a FAIL, and a missing one is fine' {
            Write-TestConfig $t 'scoring-allowlist' @('not-an-address')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'scoring-allowlist: line 1: not an address or CIDR'
            Remove-Item -LiteralPath (Join-Path $t.Etc 'scoring-allowlist')
            Write-TestConfig $t 'pre-approved' @('bad line')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 2 'pre-approved: line 1: expected: module-id category item-id'
            Remove-Item -LiteralPath (Join-Path $t.Etc 'pre-approved')
            (Invoke-TestDoctor $t).Code | Should -Be 0
        }
    }

    Context 'this host and its profile' {
        It 'a host that is not in hosts is the one FAIL, and the tools are not checked' {
            Write-TestConfig $t 'hosts' @('someone-else ring1 test windows')
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 3 "this host ($script:ThisHost) is not in hosts" 'WARN'
            (Get-TestRow $r)[6] | Should -BeExactly "WARN  tools: not checked because this host's profile is not known"
            Get-TestFix $r 3 | Should -BeExactly "add a line for $script:ThisHost to $(Join-Path $t.Etc 'hosts')"
        }

        It 'a missing hosts file is a FAIL' {
            Remove-Item -LiteralPath (Join-Path $t.Etc 'hosts')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 'hosts: missing' 'WARN'
        }

        It 'a malformed hosts line names the line' {
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 test windows", 'broken')
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 'hosts: line 2: expected: host group profile platform' 'WARN'
        }

        It 'a host on two lines is a FAIL' {
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 test windows", "$script:ThisHost ring2 test windows")
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 "this host ($script:ThisHost) is on 2 lines of hosts" 'WARN'
        }

        It 'a profile that does not exist is a FAIL' {
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 nope windows")
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 'the profile nope does not exist' 'WARN'
        }

        It 'a profile line that is not a module ID is a FAIL' {
            Write-TestProfile $t 'nonsense'
            Write-TestRelease $t
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 'profile test: line 1 is not a module ID' 'WARN'
        }

        It 'a platform this runner does not serve is a FAIL' {
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 test ubuntu")
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 "this runner does not serve this host's platform, ubuntu" 'WARN'
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 test appliance")
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 3 'is an appliance: Labyrinth never changes it' 'WARN'
        }

        It 'a profile in the configuration folder is found, as a run finds it' {
            New-Item -ItemType Directory -Path (Join-Path $t.Etc 'profiles') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $t.Etc 'profiles\mine.profile') -Value 'observe.toggle' -Encoding Ascii
            Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 mine windows")
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            @($r.Out -split "`r?`n")[3] | Should -BeExactly "OK    this host is $script:ThisHost in hosts, profile mine"
        }
    }

    Context 'the revert timer' {
        It 'a host where no revert timer can be armed is the one FAIL, with the reason' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'NO_TIMER') | Out-Null
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 4 'revert timer cannot be armed: the Task Scheduler service is not running'
        }
    }

    Context 'the clock' {
        It 'a date before this release is the one FAIL' {
            [IO.File]::WriteAllText((Join-Path $t.Lab 'CLOCK'), "2020-01-01T00:00:00Z`n")
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 5 'clock: the date is 2020-01-01, earlier than this release'
        }

        It 'no time sync is a WARN, which does not fail the check' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'NO_TIMESYNC') | Out-Null
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            $lines = @($r.Out -split "`r?`n")
            $lines[5] | Should -BeExactly 'WARN  clock: no time sync running'
            $lines[6] | Should -BeLike '      Fix: *'
            $lines[-1] | Should -BeExactly 'Ready for a run.'
            Remove-Item -LiteralPath (Join-Path $t.Lab 'NO_TIMESYNC')
            New-Item -ItemType File -Path (Join-Path $t.Lab 'TIMESYNC_UNKNOWN') | Out-Null
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0
            @($r.Out -split "`r?`n")[5] | Should -BeExactly 'WARN  clock: cannot tell whether time sync is running'
        }
    }

    Context 'the tools' {
        It 'a tool a module needs that is missing is the one FAIL, named with its module' {
            Add-TestModuleLine $t 'toggle' 'tools_windows: [no-such-tool-xyz]'
            Write-TestRelease $t
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 6 'tools for the test profile: observe.toggle is missing no-such-tool-xyz'
            Get-TestFix $r 6 | Should -BeExactly 'make these tools available on this host: no-such-tool-xyz'
        }

        It 'a tool that is present passes, and tools is not looked at on Windows' {
            Add-TestModuleLine $t 'toggle' "tools: [no-such-tool-xyz]`ntools_windows: [cmd, Get-ChildItem]"
            Write-TestRelease $t
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            @($r.Out -split "`r?`n")[6] | Should -BeExactly 'OK    tools for the test profile: present'
        }

        It 'every missing tool of every module is reported' {
            Add-TestModuleLine $t 'toggle' 'tools_windows: [no-such-tool-xyz, cmd, no-such-tool-abc]'
            Add-TestModuleLine $t 'sample' 'tools_windows: [no-such-tool-xyz]'
            Write-TestProfile $t @('observe.toggle', 'observe.sample')
            Write-TestRelease $t
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 6 'observe.toggle is missing no-such-tool-xyz, no-such-tool-abc; observe.sample is missing no-such-tool-xyz'
        }

        It 'a tools field that is not a list is a FAIL' {
            Add-TestModuleLine $t 'toggle' 'tools_windows: cmd'
            Write-TestRelease $t
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 6 'observe.toggle has a module.yml that is not valid'
        }

        It 'a tool name that begins with a dash is not valid' {
            Add-TestModuleLine $t 'toggle' 'tools_windows: [-x]'
            Write-TestRelease $t
            Assert-TestOnlyFail (Invoke-TestDoctor $t) 6 'observe.toggle has a module.yml that is not valid'
        }

        It 'the shipped inventory module lists its tools for both platforms' {
            $yml = [IO.File]::ReadAllText((Join-Path $script:Repo 'phases\lockout\modules\inventory\module.yml'))
            $yml | Should -Match '(?m)^tools: \[ss\]\r?$'
            $yml | Should -Match '(?m)^tools_windows: \[Get-NetTCPConnection\]\r?$'
        }
    }

    Context 'a stale revert timer' {
        It 'an armed timer whose time passed is the one FAIL, with the way to keep or undo' {
            $id = Get-TestArmedRun $t
            $short = $id.Substring($id.Length - 4)
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            @($r.Out -split "`r?`n")[7] | Should -BeExactly 'OK    no stale revert timer'
            Write-TestPastDue $t $id
            $r = Invoke-TestDoctor $t
            Assert-TestOnlyFail $r 7 "stale revert timer: run '$short' (armed: was due 00:05 UTC)"
            $fix = Get-TestFix $r 7
            $fix | Should -Match ([regex]::Escape("-k '$short'"))
            $fix | Should -Match ([regex]::Escape("-u '$short'"))
            $fix | Should -Match '-Root '
        }

        It 'a kept run is not stale' {
            $id = Get-TestArmedRun $t
            Write-TestPastDue $t $id
            (Invoke-TestRunCommand $t 'keep' $id).Code | Should -Be 0
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0 -Because $r.Out
            @($r.Out -split "`r?`n")[7] | Should -BeExactly 'OK    no stale revert timer'
        }
    }

    Context 'exit codes and the Next line' {
        It 'with two failures, Next names the fix of the first' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'UNTRUSTED'), (Join-Path $t.Lab 'NO_TIMER') | Out-Null
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 20
            $rows = @(Get-TestRow $r)
            $rows.Count | Should -Be 8
            $rows[1] | Should -BeLike 'FAIL*'
            $rows[4] | Should -BeLike 'FAIL*'
            $next = @($r.Out -split "`r?`n" | Where-Object { $_ -like 'Next: *' })
            $next | Should -Be @("Next: $(Get-TestFix $r 1)")
            @($r.Out -split "`r?`n")[-1] | Should -BeExactly $next[0]
        }

        It 'a WARN alone never fails it: exit 0 and Ready for a run.' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'NO_TIMESYNC') | Out-Null
            Remove-Item -LiteralPath (Join-Path $t.Lab 'release.sha256')
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 0
            $r.Out | Should -Match 'WARN  no release.sha256'
            $r.Out | Should -Match 'WARN  clock'
            @($r.Out -split "`r?`n")[-1] | Should -BeExactly 'Ready for a run.'
            $r.Out | Should -Not -Match 'Next:'
        }

        It 'not an Administrator: it is refused with 20, and no check runs' {
            New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
            $r = Invoke-TestDoctor $t
            $r.Code | Should -Be 20
            @($r.Err -split "`r?`n")[0] | Should -BeExactly 'labyrinth: -Doctor needs an elevated Administrator session'
            $r.Out | Should -Not -Match '(?m)^OK '
        }

        It 'usage errors exit 40: an extra word, a second action, an option it does not use' {
            (Invoke-TestDoctor $t @('extra')).Code | Should -Be 40
            (Invoke-TestDoctor $t @('-k', '4f2a')).Code | Should -Be 40
            (Invoke-TestDoctor $t @('-All')).Code | Should -Be 40
            (Invoke-TestDoctor $t @('-Only', 'observe.toggle')).Code | Should -Be 40
        }

        It 'an option the check does not use only warns' {
            $r = Invoke-TestDoctor $t @('-Profile', 'test')
            $r.Code | Should -Be 0 -Because $r.Out
            $r.Err | Should -Match 'is not used by -Doctor'
            @($r.Out -split "`r?`n")[-1] | Should -BeExactly 'Ready for a run.'
        }

        It 'a configuration folder that does not exist is a FAIL, not an error' {
            $nowhere = Join-Path $TestDrive 'nowhere'
            $r = Invoke-TestLabCapture $t @('-Doctor', '-Root', $t.Root, '-Config', $nowhere)
            $r.Code | Should -Be 20
            $r.Out | Should -Match ([regex]::Escape("FAIL  the configuration folder $nowhere does not exist"))
        }
    }

    Context 'read-only' {
        It 'nothing changes: the files, sizes, times and hashes are the same after a clean run' {
            New-Item -ItemType Directory -Path $t.Root -Force | Out-Null
            $before = Get-TestSnapshot $t
            (Invoke-TestDoctor $t).Code | Should -Be 0
            Get-TestSnapshot $t | Should -BeExactly $before
        }

        It 'nothing changes when checks fail or warn, or with a run on the host' {
            $id = Get-TestArmedRun $t
            Write-TestPastDue $t $id
            foreach ($f in 'UNTRUSTED', 'NO_TIMER', 'NO_TIMESYNC') { New-Item -ItemType File -Path (Join-Path $t.Lab $f) | Out-Null }
            Write-TestConfig $t 'never-ban' @('bad line')
            $arms = @(Get-Content -LiteralPath (Join-Path $t.Lab 'timer.log')).Count
            $before = Get-TestSnapshot $t
            (Invoke-TestDoctor $t).Code | Should -Be 20
            Get-TestSnapshot $t | Should -BeExactly $before
            @(Get-Content -LiteralPath (Join-Path $t.Lab 'timer.log')).Count | Should -Be $arms
        }

        It 'nothing changes on a changed release, when asking for help, or when not an Administrator' {
            New-Item -ItemType Directory -Path $t.Root -Force | Out-Null
            Add-Content -LiteralPath (Join-Path $t.Lab 'core\Log\Log.ps1') -Value '# changed'
            $before = Get-TestSnapshot $t
            (Invoke-TestDoctor $t).Code | Should -Be 20
            (Invoke-TestLabCapture $t @('-Doctor', '-h')).Code | Should -Be 20
            Get-TestSnapshot $t | Should -BeExactly $before
            Write-TestRelease $t
            New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
            $before = Get-TestSnapshot $t
            (Invoke-TestDoctor $t).Code | Should -Be 20
            Get-TestSnapshot $t | Should -BeExactly $before
        }

        It 'takes no lock and makes no run, log or folder' {
            New-Item -ItemType Directory -Path (Join-Path $t.Root 'state') -Force | Out-Null
            (Invoke-TestDoctor $t).Code | Should -Be 0
            Test-Path -LiteralPath (Join-Path $t.Root 'state\runs') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $t.Root 'logs') | Should -BeFalse
            @(Get-ChildItem -LiteralPath (Join-Path $t.Root 'state') -Force).Count | Should -Be 0
        }
    }

    Context 'help and completion' {
        It '-h doctor describes it, and the main help lists it' {
            $r = Invoke-TestLabCapture $t @('-h', 'doctor')
            $r.Code | Should -Be 0
            $r.Out | Should -Match 'Usage: .* --doctor \[--root DIR\] \[--config DIR\]'
            $r.Out | Should -Match 'Exit: 0 ready, 20 a check failed or not root, 40 error\.'
            $r = Invoke-TestLabCapture $t @('-h')
            $r.Out | Should -Match '--doctor            check that this host is ready for a run'
            @($r.Out -split "`r?`n").Count | Should -BeLessOrEqual 24
        }

        It 'tab completion offers -Doctor, and after it only the options that fit' {
            $r = Invoke-TestLabCapture $t @('--complete', '--')
            @($r.Out -split "`r?`n") | Should -Contain '-Doctor'
            $r = Invoke-TestLabCapture $t @('--complete', '-Doctor', '--')
            $c = @($r.Out -split "`r?`n")
            $c | Should -Not -Contain '-Doctor'
            $c | Should -Not -Contain '-Run'
            $c | Should -Not -Contain '-All'
            $c | Should -Contain '-Root'
        }

        It 'a near miss of the action gets the real form' {
            $r = Invoke-TestLabCapture $t @('doctor')
            $r.Code | Should -Be 40
            $r.Err | Should -Match "'doctor' is not a phase\. Did you mean '.* -Doctor'\?"
        }
    }
}
