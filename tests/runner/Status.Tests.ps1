#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 with no action: the status of this host
# and the next step; -Manual, the full manual; and -NoRevert
# (docs\Conventions.md section 3.1). Mirrors status.bats. The host-specific
# parts are test doubles (tests\fixtures\Doubles.ps1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Get-TestStatus T [ARGS]: the status, with the test's data root and
    # configuration; Lines holds its lines.
    function Get-TestStatus {
        param($T, [string[]] $Extra = @())
        $r = Invoke-TestLabCapture $T (@('-Root', $T.Root, '-Config', $T.Etc) + $Extra)
        $r | Add-Member -NotePropertyName Lines -NotePropertyValue @($r.Out -split "`r?`n")
        return $r
    }

    # Get-TestWord PATH: PATH as the runner writes it in a command to paste.
    function Get-TestWord {
        param([string] $Word)
        if ($Word -match '^[A-Za-z0-9\\/._:@=-]+$') { return $Word }
        return "'" + $Word.Replace("'", "''") + "'"
    }

    # Write-TestRun T PHASE N [ACTION NOTE]: a run of PHASE, with a manifest
    # that ends with ACTION (run_kept by default), as -r would leave it.
    function Write-TestRun {
        param($T, [string] $Phase, [int] $N, [string] $Action = 'run_kept', [string] $Note = '')
        $id = "20261002T14030${N}Z-000$N"
        $dir = Join-Path $T.Root "state\runs\$id"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $lines = @(
            ('{{"ts":"2026-10-02T14:03:0{0}Z","run":"{1}","module":"","action":"run_start","target":"{2}","note":"phase {3}, profile test, group ring1"}}' -f $N, $id, $script:ThisHost, $Phase)
            ('{{"ts":"2026-10-02T14:04:0{0}Z","run":"{1}","module":"","action":"{2}","target":"","note":"{3}"}}' -f $N, $id, $Action, $Note)
        )
        [IO.File]::WriteAllText((Join-Path $dir 'manifest.jsonl'), (($lines | ForEach-Object { "$_`n" }) -join ''))
    }
}

Describe 'labyrinth.ps1 status' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        $opts = " -Root $(Get-TestWord $t.Root) -Config $(Get-TestWord $t.Etc)"
        $hostsFile = Join-Path $t.Etc 'hosts'
    }

    It 'a new host: its group, no runs, no timer, and the first phase to preview' {
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $version = ((Invoke-TestLabCapture $t @('-V')).Out -split ' ')[2]
        $r.Lines | Should -Be @(
            "labyrinth ${version}: status of host $script:ThisHost",
            'Group:    ring1, profile test',
            'lockout   not run',
            'observe   not run',
            'deceive   not run',
            'sustain   not run',
            'Timer:    none armed',
            "Next: preview lockout: $($t.Self) lockout$opts")
        $r.Err | Should -BeNullOrEmpty
    }

    It 'the status only reads: it creates nothing and takes no lock' {
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $t.Root | Should -Not -Exist
    }

    It 'with no hosts file, or this host not in it, the next step is to list it' {
        Remove-Item -LiteralPath $hostsFile
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[1] | Should -BeExactly "Group:    unknown: there is no $hostsFile yet"
        $r.Lines[-1] | Should -BeExactly "Next: list this host in $hostsFile, then run $($t.Self)$opts again."
        Write-TestConfig $t 'hosts' @('otherhost ring1 test windows')
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[1] | Should -BeExactly "Group:    unknown: this host is not in $hostsFile"
        $r.Lines[-1] | Should -BeLike "Next: list this host in *"
    }

    It 'a malformed hosts file is named, and still exits 0' {
        Write-TestConfig $t 'hosts' @('not a host line')
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[1] | Should -BeExactly "Group:    unknown: $hostsFile is malformed"
        $r.Lines[-1] | Should -BeExactly "Next: correct $hostsFile, then run $($t.Self)$opts again."
        $r.Err | Should -Not -Match 'At line:|Exception|CategoryInfo'
    }

    It 'a host in the manual group is configured by hand' {
        Write-TestHost $t 'manual'
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[1] | Should -BeExactly 'Group:    manual, profile test'
        $r.Lines[-1] | Should -BeExactly 'Next: none: this host is in the manual group; configure it by hand, from its runbook.'
    }

    It 'an armed timer comes first: its run, when it fires, and the keep command' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $short = $id.Substring($id.Length - 4)
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $start = '{0}-{1}-{2} {3}:{4}' -f $id.Substring(0, 4), $id.Substring(4, 2), $id.Substring(6, 2), $id.Substring(9, 2), $id.Substring(11, 2)
        $r.Lines[3] | Should -BeLike "observe   armed: undo at * UTC (run $short, $start UTC)"
        $r.Out | Should -Match ([regex]::Escape("Timer:    run $short is undone at "))
        $r.Lines[-1] | Should -BeExactly "Next: check you can log in from a NEW session, then $($t.Self) -k '$short'$opts."
    }

    It 'the latest run of each phase is shown; after every phase, the next step is -Probe' {
        Write-TestRun $t 'lockout' 1
        Write-TestRun $t 'observe' 2
        Write-TestRun $t 'deceive' 3
        Write-TestRun $t 'sustain' 4
        Write-TestRun $t 'observe' 5 'run_rolled_back' 'exit 0'
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[2] | Should -BeExactly 'lockout   kept (run 0001, 2026-10-02 14:03 UTC)'
        $r.Lines[3] | Should -BeExactly 'observe   undone (run 0005, 2026-10-02 14:03 UTC)'
        # The undone phase is the next one to preview.
        $r.Lines[-1] | Should -BeExactly "Next: preview observe: $($t.Self) observe$opts"
        Write-TestRun $t 'observe' 6
        $r = Get-TestStatus $t
        $r.Lines[3] | Should -BeExactly 'observe   kept (run 0006, 2026-10-02 14:03 UTC)'
        $r.Lines[-1] | Should -BeExactly "Next: test the scored services: $($t.Self) -Probe$opts"
    }

    It "a -NoRevert run shows as 'no revert'" {
        Write-TestRun $t 'lockout' 1 'run_no_revert' 'no revert timer: -NoRevert'
        $r = Get-TestStatus $t
        $r.Lines[2] | Should -BeExactly 'lockout   no revert (run 0001, 2026-10-02 14:03 UTC)'
        $r.Lines[-1] | Should -BeExactly "Next: preview observe: $($t.Self) observe$opts"
    }

    It 'not as an Administrator: the usage lines and how to run it elevated, still exit 0' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        $r = Get-TestStatus $t
        $r.Code | Should -Be 0
        $r.Lines[0] | Should -BeExactly "Usage: $($t.Self) PHASE                preview a phase: nothing changes"
        $r.Out | Should -Match 'needs an elevated Administrator session'
        $r.Out | Should -Match ([regex]::Escape("'$($t.Self) -h' lists every action."))
        $r.Out | Should -Not -Match 'Group:'
        $t.Root | Should -Not -Exist
    }

    It 'an option only a preview or -r uses makes the line a preview, not the status' {
        $r = Get-TestStatus $t @('-P', 'test')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'no phase or action given'
    }
}

Describe 'labyrinth.ps1 -Manual' {
    BeforeEach {
        $t = Initialize-TestLab
        $installed = Join-Path "$env:ProgramFiles" 'WindowsPowerShell\Modules\Labyrinth\en-US\about_Labyrinth.help.txt'
    }

    It "-Manual prints this copy's help topic when the output is not a console" {
        New-Item -ItemType Directory -Path (Join-Path $t.Lab 'manual') | Out-Null
        [IO.File]::WriteAllText((Join-Path $t.Lab 'manual\about_Labyrinth.help.txt'), "TOPIC about_Labyrinth`nMANUALMARKER`n")
        $r = Invoke-TestLabCapture $t @('-Manual')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'MANUALMARKER'
        $r.Err | Should -BeNullOrEmpty
    }

    It '-Manual falls back to the Markdown source, and says so when there is no manual' {
        if (Test-Path -LiteralPath $installed) { Set-ItResult -Skipped -Because 'Labyrinth is installed on this machine' }
        $r = Invoke-TestLabCapture $t @('-Manual')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("this copy has no manual: there is no $(Join-Path $t.Lab 'manual\about_Labyrinth.help.txt')"))
        New-Item -ItemType Directory -Path (Join-Path $t.Lab 'docs\manual') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $t.Lab 'docs\manual\labyrinth.md'), "# Labyrinth manual`nSOURCEMARKER @CMD@`n<!-- linux -->`nLINUXONLY`n<!-- end -->`n<!-- windows -->`nWINDOWSONLY`n<!-- end -->`n")
        $r = Invoke-TestLabCapture $t @('-Manual')
        $r.Code | Should -Be 0
        $r.Out | Should -Match ([regex]::Escape('SOURCEMARKER .\labyrinth.ps1'))
        $r.Out | Should -Match 'WINDOWSONLY'
        $r.Out | Should -Not -Match 'LINUXONLY|<!--'
    }

    It '-Manual needs no Administrator and creates nothing' {
        New-Item -ItemType Directory -Path (Join-Path $t.Lab 'manual') | Out-Null
        [IO.File]::WriteAllText((Join-Path $t.Lab 'manual\about_Labyrinth.help.txt'), "MANUALMARKER`n")
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        $r = Invoke-TestLabCapture $t @('-Manual', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        $t.Root | Should -Not -Exist
    }
}

Describe 'labyrinth.ps1 -NoRevert' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $toggle = Join-Path $lab 'toggle.conf'
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It '-NoRevert: no timer, no keep question, recorded, and undone only by -u' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1') @('-NoRevert')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
        $timerLog = Join-Path $lab 'timer.log'
        if (Test-Path -LiteralPath $timerLog) { [IO.File]::ReadAllText($timerLog) | Should -Not -Match '(?m)^arm ' }
        (Join-Path $t.Root "state\runs\$id\timer") | Should -Not -Exist
        $r.Output | Should -Match ([regex]::Escape('No revert timer (-NoRevert): the changes stay until you undo them.'))
        $r.Output | Should -Not -Match 'Type keep to keep'
        $r.Output | Should -Match ([regex]::Escape("so they stay. To undo them: $($t.Self) -u '$($id.Substring($id.Length - 4))'"))
        $r.Output | Should -Match ([regex]::Escape('Revert timer: none (-NoRevert).'))
        Get-TestManifest $t $id | Should -Match '"action":"run_no_revert"'
        $r = Invoke-TestLab $t @('-History', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Output | Should -Match ('{0} observe .*no revert' -f [regex]::Escape($id))
        $r = Invoke-TestRunCommand $t 'keep' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Match ([regex]::Escape("nothing to keep: run $id has no revert timer (-NoRevert), so its changes stay"))
        Get-TestManifest $t $id | Should -Not -Match '"action":"run_kept"'
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $toggle | Should -Not -Exist
    }

    It '-NoRevert keeps nothing early: there is no timer to keep it from' {
        Write-TestProfile $t 'observe.keeper'
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        $r = Invoke-TestApply $t @('labadmin', 'ring1') @('-NoRevert')
        $r.Code | Should -Be 0
        $m = Get-TestManifest $t (Get-TestRunId $r.Output)
        $m | Should -Not -Match '"action":"module_kept"'
        $m | Should -Not -Match '"action":"run_kept"'
        $r.Output | Should -Not -Match 'is kept once it verifies'
    }

    It '-h with -NoRevert is help: nothing runs' {
        $r = Invoke-TestApply $t @('labadmin', 'ring1') @('-NoRevert', '-h')
        $r.Code | Should -Be 0
        $toggle | Should -Not -Exist
        $t.Root | Should -Not -Exist
    }
}
