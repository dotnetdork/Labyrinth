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
        foreach ($topic in @('') + $topics) {
            $argv = @('help')
            if ($topic -ne '') { $argv += $topic }
            $r = Invoke-TestLabStreams $t $argv
            $lines = @($r.Out -split "`r?`n")
            $r.Code | Should -Be 0 -Because "help $topic"
            $lines.Count | Should -BeLessOrEqual 15 -Because "help $topic"
            ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 78 -Because "help $topic"
            @($lines | Where-Object { $_ -like 'Exit: *' }).Count | Should -Be 1 -Because "help $topic"
            @($lines | Where-Object { $_ -like 'Example: *' }).Count | Should -Be 1 -Because "help $topic"
            $lines[0] | Should -BeLike 'Usage: labyrinth.ps1 *' -Because "help $topic"
        }
    }

    It 'help X, X -Help and X -h print the same' {
        foreach ($topic in $topics) {
            $want = (Invoke-TestLabStreams $t @('help', $topic)).Out
            foreach ($form in @('-Help', '-h', '--help')) {
                $r = Invoke-TestLabStreams $t @($topic, $form)
                $r.Code | Should -Be 0 -Because "$topic $form"
                $r.Out | Should -BeExactly $want -Because "$topic $form"
            }
        }
    }

    It 'the general help lists every command' {
        $r = Invoke-TestLabStreams $t @('help')
        $listed = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^  [a-z]+ ' } | ForEach-Object { ($_.Trim() -split ' ')[0] })
        ($listed -join ' ') | Should -BeExactly ($topics -join ' ')
    }

    It 'help for an unknown command is a usage error with a suggestion' {
        $r = Invoke-TestLabStreams $t @('help', 'aply')
        $r.Code | Should -Be 40
        $r.Err | Should -Match "did you mean 'apply'"
    }

    It 'Get-Help shows the synopsis, not the Requires line' {
        $synopsis = (Get-Help (Join-Path $script:Repo 'labyrinth.ps1')).Synopsis
        $synopsis | Should -Match 'Labyrinth'
        $synopsis | Should -Not -Match 'Requires'
    }
}
