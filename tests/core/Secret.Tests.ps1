#Requires -Version 5.1
# Pester 5 unit tests for the new-password helpers (core\secret\Secret.ps1,
# design 04, section 2.3).

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
        function Clear-LabTerminal { param([string] $Text) $script:Cleared = $Text }
        $script:TtyIn.Enqueue('done')
        $script:TtyIn.Enqueue('  Recorded ')
        $out = @(Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue')
        $out | Should -Be @(0)
        $text = $script:TtyOut.ToString()
        $text | Should -Match '(?m)^      Ab3-secretvalue\r?$'
        ([regex]::Matches($text, "Type 'recorded'")).Count | Should -Be 2
        # The clear covers what was written plus each answer the console echoed.
        $prompt = "  Type 'recorded' once it is in the offline record: "
        $script:Cleared | Should -BeExactly ("`r`n  New password for testuser, shown once:`r`n`r`n      Ab3-secretvalue`r`n`r`n" +
            $prompt + "done`r`n" + $prompt + "  Recorded `r`n")
    }

    It 'show: the seed is shown and cleared the same way' {
        function Test-LabTerminal { return $true }
        function Write-LabTerminal { param([string] $Text) [void]$script:TtyOut.Append($Text) }
        function Read-LabTerminal { if ($script:TtyIn.Count -eq 0) { return $null }; return $script:TtyIn.Dequeue() }
        function Clear-LabTerminal { param([string] $Text) $script:Cleared = $Text }
        $script:TtyIn.Enqueue('recorded')
        Show-LabSeed -Label 'web01' -Seed 'ABCD-EFGH' | Should -Be 0
        $script:Cleared | Should -BeExactly ("`r`n  Decoy seed for web01, shown once:`r`n`r`n      ABCD-EFGH`r`n`r`n" +
            "  Type 'recorded' once it is in the offline record and the team chat: recorded`r`n")
    }

    It 'clear: counts each line written, and the lines that wrap' {
        $block = "`r`n  New password for testuser, shown once:`r`n`r`n      Ab3-secretvalue`r`n`r`n"
        $prompt = "  Type 'recorded' once it is in the offline record: "
        # Five line ends in the block, one per answer: as the bash version counts.
        Get-LabTerminalRowCount -Text ($block + $prompt + "recorded`r`n") -Width 120 | Should -Be 6
        Get-LabTerminalRowCount -Text ($block + $prompt + "done`r`n" + $prompt + "recorded`r`n") -Width 120 | Should -Be 7
        # On a 25-column console the 40-character title and the prompt with its
        # answer (60 characters) wrap, taking 2 and 3 rows; the rest take 1.
        Get-LabTerminalRowCount -Text ($block + $prompt + "recorded`r`n") -Width 25 | Should -Be 9
        # A line that exactly fills the width counts one row more, never less.
        Get-LabTerminalRowCount -Text (('x' * 20) + "`r`n") -Width 20 | Should -Be 2
        Get-LabTerminalRowCount -Text '' -Width 80 | Should -Be 0
    }

    It 'clear: covers the secret when printing it scrolled a full window' {
        # A 30-row buffer, the size of the window, with the prompt on its last
        # row (29). Writing 6 rows scrolls the buffer 6 times: the cursor stays
        # on row 29 and the secret, written 3 rows below the start, moves up to
        # row 29 - 6 + 3 = 26. A row saved before printing (29) misses it.
        $lines = 6
        $top = Get-LabClearRow -End 29 -Lines $lines
        $top | Should -Be 23
        $secretRow = 29 - $lines + 3
        $secretRow | Should -BeGreaterOrEqual $top
        $secretRow | Should -BeLessOrEqual 29
        # No scrolling: the cursor moved from row 4 to row 10, and the clear
        # starts at row 4, where the shown block started.
        Get-LabClearRow -End 10 -Lines 6 | Should -Be 4
        # More rows written than the buffer holds: clear from the top.
        Get-LabClearRow -End 5 -Lines 9 | Should -Be 0
    }

    It 'show: fails when the console goes before the answer, and is blocked without one' {
        function Test-LabTerminal { return $true }
        function Write-LabTerminal { param([string] $Text) [void]$script:TtyOut.Append($Text) }
        function Read-LabTerminal { return $null }
        function Clear-LabTerminal { param([string] $Text) $script:Cleared = $Text }
        Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue' | Should -Be 1
        $script:Cleared | Should -BeNullOrEmpty

        function Test-LabTerminal { return $false }
        [void]$script:TtyOut.Clear()
        Show-LabSecret -Label 'testuser' -Secret 'Ab3-secretvalue' 2> $null | Should -Be 20
        $script:TtyOut.Length | Should -Be 0
        Test-LabSecretTerminal | Should -BeFalse
    }
}
