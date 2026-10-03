#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 command-line parsing, from the cases
# shared with args.bats (tests\runner\args-cases.txt; docs\Conventions.md 3.1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
}

Describe 'labyrinth.ps1 command line' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'every shared command-line case gives its exit code and message' {
        $failed = @()
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'args-cases.txt'))) {
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $code, $stream, $text, $words = $line -split '\|', 4
            $words = $words.Replace('@ROOT@', $t.Root).Replace('@ETC@', $t.Etc)
            $text = $text.Replace('@SELF@', 'labyrinth.ps1')
            $argv = @($words -split ' ' | Where-Object { $_ -ne '' })
            $r = Invoke-TestLabCapture $t $argv
            $got = $r.Out
            if ($stream -eq 'err') { $got = $r.Err }
            if ("$($r.Code)" -ne $code -or -not $got.Contains($text)) {
                $failed += "[$words]: exit $($r.Code) (want $code), $stream lacks '$text'`nstdout: $($r.Out)`nstderr: $($r.Err)"
            }
            # A usage error is the program's own message, never PowerShell's.
            if ($r.Err -match 'At line:|Exception|CategoryInfo') { $failed += "[$words]: PowerShell error text: $($r.Err)" }
        }
        $failed -join "`n" | Should -BeNullOrEmpty
    }

    It 'a usage error prints two lines, both on stderr' {
        $r = Invoke-TestLabCapture $t @('obsrve')
        $r.Code | Should -Be 40
        $r.Out | Should -BeNullOrEmpty
        @($r.Err -split "`r?`n").Count | Should -Be 2
    }

    It 'nothing is created by a usage error, help or the version' {
        foreach ($a in @('obsrve', 'help', '-V')) { Invoke-TestLabCapture $t @('-Root', $t.Root, $a) | Out-Null }
        $t.Root | Should -Not -Exist
    }

    It 'a warning about an unused option never comes before an error' {
        $r = Invoke-TestLabCapture $t @('-BreakGlass', 'root', '-Root', 'relative', 'observe')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'full path'
        $r.Err | Should -Not -Match 'warning'
    }

    It 'a warning about an unused option never comes before a run-time error' {
        $r = Invoke-TestLabCapture $t @('plan', 'observe', '-BreakGlass', 'root', '-Root', $t.Root, '-Config', (Join-Path $t.Etc 'missing'))
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'does not exist'
        $r.Err | Should -Not -Match 'warning'
        $r = Invoke-TestLabCapture $t @('keep', '4f2a', '-Profile', 'test', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Err | Should -Match "no run ending in '4f2a'"
        $r.Err | Should -Not -Match 'warning'
    }

    It 'rollback with no run, not as an Administrator, says who can list the runs' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        $r = Invoke-TestLabCapture $t @('rollback', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("as Administrator, 'labyrinth.ps1 runs' lists them"))
    }

    It 'a Windows path with forward slashes is accepted' {
        $r = Invoke-TestLabCapture $t @('plan', 'observe', '-Profile', 'test', '-Root', $t.Root.Replace('\', '/'), '-Config', $t.Etc.Replace('\', '/'))
        $r.Code | Should -Be 10
        $r.Err | Should -Not -Match 'full path'
    }

    It 'a run ID PowerShell read as a number is refused with a hint to quote it' {
        $o = "-Root '$($t.Root)' -Config '$($t.Etc)'"
        $line = "& '$(Join-Path $t.Lab 'labyrinth.ps1')' keep 0123 $o; exit `$LASTEXITCODE"
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # The message goes to the process's stderr, so capture it out here.
            $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $line 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        $code | Should -Be 40
        (@($out) | ForEach-Object { "$_" }) -join "`n" | Should -Match 'put it in quotes'
    }
}
