#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -h: the shape of the main help and of every
# topic, the ways to ask for one, that help never runs anything, and the
# comment-based help (docs\Conventions.md 3.2, 3.3). Mirrors help.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
    $t = Initialize-TestLab
    # Every topic with a page of its own; the basics page is longer.
    $topics = @('run', 'keep', 'undo', 'history', 'probe', 'version',
        'profile', 'root', 'config', 'break-glass', 'confirm-group', 'approve', 'all',
        'lockout', 'observe', 'deceive', 'sustain')
    $mainFirst = 'Usage: laby PHASE                preview a phase: nothing changes'
}

Describe 'labyrinth.ps1 help' {
    It 'the main help is one screen: Usage, Actions and Options, the manual last' {
        $r = Invoke-TestLabCapture $t @('-h')
        $r.Code | Should -Be 0
        $lines = @($r.Out.TrimEnd() -split "`r?`n")
        $lines.Count | Should -BeLessOrEqual 24
        ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 78
        $lines[0] | Should -BeExactly $mainFirst
        @($lines | Where-Object { $_ -like 'Actions*' }).Count | Should -Be 1
        $lines -ccontains 'Options:' | Should -BeTrue
        @($lines | Where-Object { $_ -like 'Exit: *' }).Count | Should -Be 1
        $r.Out | Should -Match 'an action, option, phase or basics'
        $lines[-1] | Should -BeExactly 'Full manual: docs/manual/labyrinth.md in the release'
    }

    It 'every topic is short, fits 78 columns, and has one Usage, one Exit, an Example and See also' {
        foreach ($topic in $topics + @('basics')) {
            $r = Invoke-TestLabCapture $t @('-h', $topic)
            $r.Code | Should -Be 0 -Because "-h $topic"
            $lines = @($r.Out.TrimEnd() -split "`r?`n")
            $max = 18
            if ($topic -eq 'basics') { $max = 24 }
            $lines.Count | Should -BeLessOrEqual $max -Because "-h $topic"
            ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 78 -Because "-h $topic"
            $lines[0].StartsWith('Usage: laby ') | Should -BeTrue -Because "-h $topic"
            @($lines | Where-Object { $_ -like 'Exit: *' }).Count | Should -Be 1 -Because "-h $topic"
            @($lines | Where-Object { $_ -like 'Example: *' }).Count | Should -Be 1 -Because "-h $topic"
            if ($topic -ne 'basics') {
                @($lines | Where-Object { $_ -like 'See also: *' }).Count | Should -Be 1 -Because "-h $topic"
            }
        }
    }

    It 'the help names the command laby, not the way the runner was started' {
        $out = (Invoke-TestLabCapture $t @('-h')).Out
        $out.Contains($t.Self) | Should -BeFalse
        $out.Contains('labyrinth.ps1') | Should -BeFalse
        $out = (Invoke-TestLabCapture $t @('-h', 'run')).Out
        $out.Contains($t.Self) | Should -BeFalse
        $out | Should -Match 'Example: laby -r lockout'
    }

    It 'an action, its long name and its topic word print the same page' {
        $forms = @{
            'run'     = @(@('-r', '-h'), @('-Run', '-Help'), @('--run', '--help'), @('-h', 'run'), @('-Help', 'RUN'), @('-h', 'Run'))
            'undo'    = @(@('-u', '-h'), @('-Undo', '-Help'), @('-u', '4f2a', '-h'), @('-h', '-u'))
            'keep'    = @(@('-k', '-h'), @('-Keep', '-Help'), @('-k=4f2a', '-h'))
            'history' = @(@('-History', '-h'), @('--history', '--help'))
            'observe' = @(@('observe', '-h'), @('observe', '-Help'), @('OBSERVE', '-h'))
        }
        foreach ($topic in $forms.Keys) {
            $want = (Invoke-TestLabCapture $t @('-h', $topic)).Out
            foreach ($argv in $forms[$topic]) {
                $r = Invoke-TestLabCapture $t $argv
                $r.Code | Should -Be 0 -Because ($argv -join ' ')
                $r.Out | Should -BeExactly $want -Because ($argv -join ' ')
            }
        }
    }

    It '-h, -Help, --help and /? print the main help, and so does typing nothing' {
        $want = (Invoke-TestLabCapture $t @('-h')).Out
        foreach ($a in @('-Help', '--help', '/?')) {
            $r = Invoke-TestLabCapture $t @($a)
            $r.Code | Should -Be 0 -Because $a
            $r.Out | Should -BeExactly $want -Because $a
        }
        $r = Invoke-TestLabCapture $t @()
        $r.Code | Should -Be 0
        $r.Out | Should -BeExactly $want
    }

    It 'help wins over everything else on the line, even a mistake' {
        $want = (Invoke-TestLabCapture $t @('-h', 'observe')).Out
        $r = Invoke-TestLabCapture $t @('observe', 'bogus', '-h')
        $r.Code | Should -Be 0
        $r.Out | Should -BeExactly $want
        $r = Invoke-TestLabCapture $t @('-u', '4f2a', '-k', '4f2a', '--bogus', '-h')
        $r.Code | Should -Be 0
        $r.Out | Should -Match '^Usage: laby -u ID'
        $r = Invoke-TestLabCapture $t @('-Root', 'relative', '-Profile', 'a;b', '-h')
        $r.Code | Should -Be 0
        @($r.Out -split "`r?`n")[0] | Should -BeExactly 'Usage: laby [-r] PHASE -P NAME'
    }

    It 'help runs nothing: no data root, no configuration read, no Administrator needed' {
        Remove-Item -LiteralPath $t.Etc -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') -Force | Out-Null
        try {
            foreach ($f in @(@('-h'), @('-h', 'run'), @('-r', '-h'), @('-u', '-h'), @('-History', '-Help'),
                    @('-h', 'basics'), @('-h', 'bogus'), @('-h', 'observe.sample'))) {
                $r = Invoke-TestLabCapture $t (@('-Root', $t.Root, '-Config', $t.Etc) + $f)
                $r.Code | Should -Be 0 -Because ($f -join ' ')
                $t.Root | Should -Not -Exist -Because ($f -join ' ')
            }
        } finally {
            Remove-Item -LiteralPath (Join-Path $t.Lab 'NOT_ADMIN') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'an unknown topic is one line, the main help, and exit 0' {
        $r = Invoke-TestLabCapture $t @('-h', 'bogus')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines[0] | Should -BeExactly "No help for 'bogus'. Here is the main help."
        $lines[1] | Should -BeExactly $mainFirst
        $r = Invoke-TestLabCapture $t @('-h', 'obsrve')
        $r.Code | Should -Be 0
        @($r.Out -split "`r?`n")[0] | Should -BeExactly "No help for 'obsrve' (did you mean 'observe'?). Here is the main help."
        (Invoke-TestLabCapture $t @('-h', 'basic')).Out | Should -Match "did you mean 'basics'"
    }

    It 'the old command words are no help topics' {
        foreach ($w in @('plan', 'apply', 'rollback')) {
            $r = Invoke-TestLabCapture $t @('-h', $w)
            $r.Code | Should -Be 0
            $first = @($r.Out -split "`r?`n")[0]
            $first | Should -BeLike "No help for '$w'*" -Because $w
            $first | Should -Not -Match 'did you mean' -Because $w
        }
    }

    It 'a usage error points to the help of what was typed, the way the runner was started' {
        $r = Invoke-TestLabCapture $t @('obsrve')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("Try '$($t.Self) -h'."))
        $saved = [Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory = $t.Lab
            $r = Invoke-TestLabCapture $t @('bogus')
            $r.Err | Should -Match ([regex]::Escape("Try '.\labyrinth.ps1 -h'."))
            $r = Invoke-TestLabCapture $t @('-u', '4f2a', '--bogus')
            $r.Err | Should -Match ([regex]::Escape("Try '.\labyrinth.ps1 -u -h'."))
        } finally {
            [Environment]::CurrentDirectory = $saved
        }
    }

    It 'the actions that need an Administrator say so, and -h history names every state' {
        foreach ($topic in @('run', 'keep', 'undo', 'history', 'probe')) {
            (Invoke-TestLabCapture $t @('-h', $topic)).Out | Should -Match 'Administrator' -Because "-h $topic"
        }
        $out = (Invoke-TestLabCapture $t @('-h', 'history')).Out
        foreach ($s in @('armed', 'kept', 'rolled back', 'rolled back with errors', 'not kept, no timer', 'armed: timer lost')) {
            $out.Contains($s) | Should -BeTrue -Because "-h history: $s"
        }
    }

    It '-h run and -h basics mention the break-glass prompt; exits name the 20 causes' {
        $out = (Invoke-TestLabCapture $t @('-h', 'run')).Out
        $out | Should -Match 'break-glass'
        $out | Should -Match '(?m)^Blocked: not an Administrator, another run, host not in hosts, or a safety gate\.\r?$'
        (Invoke-TestLabCapture $t @('-h', 'basics')).Out | Should -Match 'break-glass'
        (Invoke-TestLabCapture $t @('-h', 'keep')).Out | Should -Match '(?m)^Blocked: not an Administrator, a file another account can change, or too late\r?$'
        (Invoke-TestLabCapture $t @('-h', 'undo')).Out | Should -Match '(?m)^Blocked: not an Administrator, or a file another account can change\.\r?$'
    }

    It '-h undo explains --all, and -h keep says an ID is always needed' {
        (Invoke-TestLabCapture $t @('-h', 'undo')).Out | Should -Match ([regex]::Escape('--all                  also undo changes kept once they verified'))
        (Invoke-TestLabCapture $t @('-h', 'keep')).Out | Should -Match 'ID is always needed'
    }

    It '-V names the runner, and -V -h is its help' {
        $v = @((Invoke-TestLabCapture $t @('-V')).Out -split "`r?`n")
        $v[0] | Should -Match '^labyrinth \S+ \(labyrinth\.ps1, for Windows\)$'
        $v[1] | Should -BeLike 'Release: *'
        @((Invoke-TestLabCapture $t @('-V', '-h')).Out -split "`r?`n")[0] | Should -BeExactly 'Usage: laby -V'
    }

    It 'the basics tell the first run with the real forms' {
        $out = (Invoke-TestLabCapture $t @('-h', 'basics')).Out
        foreach ($f in @("'laby lockout'", "'laby -r lockout'", "'laby -k ID'", "'laby -u ID'", "'laby --history'", "'laby --probe'")) {
            $out.Contains($f) | Should -BeTrue -Because $f
        }
    }

    It 'help on a module ID prints its title, its risk in words, then its about.txt' {
        $r = Invoke-TestLabCapture $t @('-h', 'observe.sample')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines[0] | Should -BeExactly 'No-op sample (observe.sample)'
        $lines -ccontains 'Risk: only looks; it never changes anything.' | Should -BeTrue
        $lines -ccontains 'Runs on: ubuntu, rhel-family, windows.' | Should -BeTrue
        $lines -ccontains 'What it changes: nothing. Its plan describes a change it never makes.' | Should -BeTrue
        foreach ($argv in @(@('-h', 'OBSERVE.SAMPLE'), @('observe.sample', '-Help'))) {
            $r = Invoke-TestLabCapture $t $argv
            $r.Code | Should -Be 0
            @($r.Out -split "`r?`n")[0] | Should -BeExactly 'No-op sample (observe.sample)'
        }
    }

    It 'help on a module without about.txt says so; any module ID works, in a profile or not' {
        $r = Invoke-TestLabCapture $t @('-h', 'observe.toggle')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines -ccontains 'Risk: changes this host; each change is saved first and can be undone.' | Should -BeTrue
        $r.Out | Should -Match '(?m)^This module has no about\.txt yet'
    }

    It 'help on an unknown module is a near-miss line and the main help; an invalid one is an error' {
        $r = Invoke-TestLabCapture $t @('-h', 'observe.sampel')
        $r.Code | Should -Be 0
        @($r.Out -split "`r?`n")[0] | Should -BeExactly "No help for 'observe.sampel' (did you mean 'observe.sample'?). Here is the main help."
        $r = Invoke-TestLabCapture $t @('-h', 'observe.badyml')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'the module\.yml of observe\.badyml is not valid: unknown key color'
    }

    It 'Get-Help shows the synopsis, not the Requires line' {
        $synopsis = (Get-Help (Join-Path $script:Repo 'labyrinth.ps1')).Synopsis
        $synopsis | Should -Match 'Labyrinth'
        $synopsis | Should -Not -Match 'Requires'
    }

    It 'Get-Help is written for operators: no design notes, examples for preview, run, history and keep' {
        $h = Get-Help (Join-Path $script:Repo 'labyrinth.ps1') -Full
        $text = ($h.Synopsis + ' ' + (($h.Description | ForEach-Object { $_.Text }) -join ' '))
        $text | Should -Not -Match 'design \d|Conventions|\$args|param block'
        $text | Should -Not -Match ([regex]::Escape('-?'))
        $examples = ($h.Examples.Example | ForEach-Object { $_.Code }) -join ' '
        $examples | Should -Match 'labyrinth\.ps1 lockout'
        $examples | Should -Match 'labyrinth\.ps1 -r lockout'
        $examples | Should -Match 'labyrinth\.ps1 -History'
        $examples | Should -Match 'labyrinth\.ps1 -k 4f2a'
        (($h.alertSet.alert | ForEach-Object { $_.Text }) -join ' ') | Should -Match 'common parameters'
    }

    It 'Get-Help lists every option the runner accepts' {
        $h = Get-Help (Join-Path $script:Repo 'labyrinth.ps1') -Full
        $text = (($h.Description | ForEach-Object { $_.Text }) -join ' ')
        foreach ($o in @('-Profile', '-Root', '-Config', '-BreakGlass', '-ConfirmGroup', '-Approve', '-All', '-History', '-Probe', '-Help', '-Version')) {
            $text | Should -Match ('(^|\s){0}\b' -f [regex]::Escape($o)) -Because "Get-Help: $o"
        }
    }

    It 'the help never offers -?, which PowerShell takes for itself' {
        foreach ($topic in @('') + $topics + @('basics')) {
            $argv = @('-h')
            if ($topic -ne '') { $argv += $topic }
            (Invoke-TestLabCapture $t $argv).Out | Should -Not -Match ([regex]::Escape('-?')) -Because "-h $topic"
        }
    }
}
