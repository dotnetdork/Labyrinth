#Requires -Version 5.1
# Pester 5 unit tests for the new-password helpers (core\secret\Secret.ps1,
# design 05, section 2.3).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
}

Describe 'new passwords' {
    It 'new: 20 characters by default, from the set, starting with a letter, one of each kind' {
        $seen = @{}
        foreach ($i in 1..50) {
            $pw = Get-LabRandomSecret
            $pw.Length | Should -Be 20
            $pw | Should -MatchExactly '^[A-HJ-NP-Za-km-z][A-HJ-NP-Za-km-z2-9_.+=-]+$'
            $pw | Should -MatchExactly '[A-Z]'
            $pw | Should -MatchExactly '[a-z]'
            $pw | Should -Match '[2-9]'
            $pw | Should -Match '[-_.+=]'
            $seen.ContainsKey($pw) | Should -BeFalse
            $seen[$pw] = $true
        }
        (Get-LabRandomSecret -Length 14).Length | Should -Be 14
        (Get-LabRandomSecret -Length 64).Length | Should -Be 64
    }

    It 'new: a length outside 14 to 64 is refused' {
        foreach ($len in 13, 65, 0, -20) {
            { Get-LabRandomSecret -Length $len } | Should -Throw '*14 to 64*'
        }
    }

    It 'the console check compiles and answers without failing' {
        (Test-LabTerminal) -is [bool] | Should -BeTrue
    }
}

Describe 'showing a new password' {
    BeforeEach {
        $script:TtyOut = New-Object System.Text.StringBuilder
        $script:TtyIn = New-Object System.Collections.Queue
        $script:Cleared = $null
    }

    It 'show: on the console only, asked again until recorded, then cleared' {
        # Stand-ins for the console primitives, found first by Show-LabSecret.
        function Test-LabTerminal { return $true }
        function Write-LabTerminal { param([string] $Text) [void]$script:TtyOut.Append($Text) }
        function Read-LabTerminal { if ($script:TtyIn.Count -eq 0) { return $null }; return $script:TtyIn.Dequeue() }
        function Get-LabTerminalRow { return 12 }
        function Clear-LabTerminal { param([int] $Row) $script:Cleared = $Row }
        $script:TtyIn.Enqueue('done')
        $script:TtyIn.Enqueue('  Recorded ')
        $out = @(Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue')
        $out | Should -Be @(0)
        $text = $script:TtyOut.ToString()
        $text | Should -Match '(?m)^      Ab3-secretvalue\r?$'
        ([regex]::Matches($text, "Type 'recorded'")).Count | Should -Be 2
        $script:Cleared | Should -Be 12
    }

    It 'show: fails when the console goes before the answer, and is blocked without one' {
        function Test-LabTerminal { return $true }
        function Write-LabTerminal { param([string] $Text) [void]$script:TtyOut.Append($Text) }
        function Read-LabTerminal { return $null }
        function Get-LabTerminalRow { return 3 }
        function Clear-LabTerminal { param([int] $Row) $script:Cleared = $Row }
        Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue' | Should -Be 1
        $script:Cleared | Should -BeNullOrEmpty

        function Test-LabTerminal { return $false }
        [void]$script:TtyOut.Clear()
        Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue' 2> $null | Should -Be 20
        $script:TtyOut.Length | Should -Be 0
        Test-LabSecretTerminal | Should -BeFalse
    }
}
