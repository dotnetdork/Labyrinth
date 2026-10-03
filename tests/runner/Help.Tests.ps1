#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 help: the shape of every topic, the ways
# to ask for it, and the comment-based help (docs\Conventions.md 3.1, 3.2).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
    $t = Initialize-TestLab
    $topics = @('plan', 'apply', 'keep', 'rollback', 'runs', 'probe', 'help', 'version')
}

Describe 'labyrinth.ps1 help' {
    It 'every topic is short, fits 78 columns, and has one Exit and one Example line' {
        foreach ($topic in @('') + $topics + @('basics')) {
            $argv = @('help')
            if ($topic -ne '') { $argv += $topic }
            $r = Invoke-TestLabCapture $t $argv
            $lines = @($r.Out -split "`r?`n")
            $r.Code | Should -Be 0 -Because "help $topic"
            # The general page also names the manual; basics is one screen.
            $max = 15
            if ($topic -eq '') { $max = 16 } elseif ($topic -eq 'basics') { $max = 24 }
            $lines.Count | Should -BeLessOrEqual $max -Because "help $topic"
            ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 78 -Because "help $topic"
            @($lines | Where-Object { $_ -like 'Exit: *' }).Count | Should -Be 1 -Because "help $topic"
            @($lines | Where-Object { $_ -like 'Example: *' }).Count | Should -Be 1 -Because "help $topic"
            $lines[0] | Should -BeLike 'Usage: labyrinth.ps1 *' -Because "help $topic"
        }
    }

    It 'help X, X -Help and X -h print the same' {
        foreach ($topic in $topics) {
            $want = (Invoke-TestLabCapture $t @('help', $topic)).Out
            foreach ($form in @('-Help', '-h', '--help')) {
                $r = Invoke-TestLabCapture $t @($topic, $form)
                $r.Code | Should -Be 0 -Because "$topic $form"
                $r.Out | Should -BeExactly $want -Because "$topic $form"
            }
        }
    }

    It 'the general help lists every command' {
        $r = Invoke-TestLabCapture $t @('help')
        $listed = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^  [a-z]+ ' } | ForEach-Object { ($_.Trim() -split ' ')[0] })
        ($listed -join ' ') | Should -BeExactly ($topics -join ' ')
    }

    It 'help for an unknown command is a usage error with a suggestion' {
        $r = Invoke-TestLabCapture $t @('help', 'aply')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "did you mean 'apply'"
        $r = Invoke-TestLabCapture $t @('help', 'basic')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "did you mean 'basics'"
    }

    It 'the general help points a beginner to help basics and names the manual' {
        $lines = @((Invoke-TestLabCapture $t @('help')).Out -split "`r?`n")
        $lines[1] | Should -Match ([regex]::Escape('labyrinth.ps1 help basics'))
        @($lines | Where-Object { $_ -like 'Manual: *' }).Count | Should -Be 1
    }

    It 'help on a module ID prints its title, its risk in words, then its about.txt' {
        $r = Invoke-TestLabCapture $t @('help', 'observe.sample')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines[0] | Should -BeExactly 'No-op sample (observe.sample)'
        $lines -ccontains 'Risk: only looks; it never changes anything.' | Should -BeTrue
        $lines -ccontains 'Runs on: ubuntu, rhel-family, windows.' | Should -BeTrue
        $lines -ccontains 'What it changes: nothing. Its plan describes a change it never makes.' | Should -BeTrue
        $r = Invoke-TestLabCapture $t @('help', 'OBSERVE.SAMPLE', '-Help')
        $r.Code | Should -Be 0
        @($r.Out -split "`r?`n")[0] | Should -BeExactly 'No-op sample (observe.sample)'
    }

    It 'help on a module without about.txt says so; any module ID works, in a profile or not' {
        $r = Invoke-TestLabCapture $t @('help', 'observe.toggle')
        $r.Code | Should -Be 0
        $lines = @($r.Out -split "`r?`n")
        $lines -ccontains 'Risk: changes this host; each change is saved first and can be undone.' | Should -BeTrue
        $r.Out | Should -Match '(?m)^This module has no about\.txt yet'
    }

    It 'help on an unknown or invalid module is an error that says why' {
        $r = Invoke-TestLabCapture $t @('help', 'observe.sampel')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("no module 'observe.sampel' (did you mean 'observe.sample'?)"))
        $r = Invoke-TestLabCapture $t @('help', 'observe.badyml')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'the module\.yml of observe\.badyml is not valid: unknown key color'
    }

    It 'no command prints three steps to start with, and exits 40' {
        $r = Invoke-TestLabCapture $t @()
        $r.Code | Should -Be 40
        $lines = @($r.Err -split "`r?`n")
        $lines -ccontains 'Start here:' | Should -BeTrue
        @($lines | Where-Object { $_ -like '  1. labyrinth.ps1 help basics *' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -like '  2. labyrinth.ps1 plan lockout *' }).Count | Should -Be 1
    }

    It 'Get-Help shows the synopsis, not the Requires line' {
        $synopsis = (Get-Help (Join-Path $script:Repo 'labyrinth.ps1')).Synopsis
        $synopsis | Should -Match 'Labyrinth'
        $synopsis | Should -Not -Match 'Requires'
    }

    It 'Get-Help is written for operators: no design notes, examples for runs and keep' {
        $h = Get-Help (Join-Path $script:Repo 'labyrinth.ps1') -Full
        $text = ($h.Synopsis + ' ' + (($h.Description | ForEach-Object { $_.Text }) -join ' '))
        $text | Should -Not -Match 'design \d|Conventions|\$args|param block'
        $text | Should -Not -Match ([regex]::Escape('-?'))
        $examples = ($h.Examples.Example | ForEach-Object { $_.Code }) -join ' '
        $examples | Should -Match 'labyrinth\.ps1 runs'
        $examples | Should -Match 'labyrinth\.ps1 keep'
        (($h.alertSet.alert | ForEach-Object { $_.Text }) -join ' ') | Should -Match 'common parameters'
    }

    It 'the help never offers -?, which PowerShell takes for itself' {
        foreach ($topic in @('') + $topics) {
            $argv = @('help')
            if ($topic -ne '') { $argv += $topic }
            (Invoke-TestLabCapture $t $argv).Out | Should -Not -Match ([regex]::Escape('-?')) -Because "help $topic"
        }
    }
}
