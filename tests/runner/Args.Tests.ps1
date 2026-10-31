#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 command-line parsing, from the cases
# shared with args.bats (tests\runner\args-cases.txt; docs\Conventions.md 3.3).

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
            $text = $text.Replace('@SELF@', $t.Self)
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

    It 'a usage error prints the message, a fix if there is one, and the pointer, all on stderr' {
        $r = Invoke-TestLabCapture $t @('obsrve')
        $r.Code | Should -Be 40
        $r.Out | Should -BeNullOrEmpty
        @($r.Err -split "`r?`n").Count | Should -Be 3
        $r = Invoke-TestLabCapture $t @('-x')
        $r.Code | Should -Be 40
        $r.Out | Should -BeNullOrEmpty
        @($r.Err -split "`r?`n").Count | Should -Be 2
        @($r.Err -split "`r?`n") | Should -Be @("$($t.Name): unknown option '-x'", "Try '$($t.Self) -h'.")
    }

    It 'the old command words are plain mistakes, with no hint that maps them' {
        foreach ($w in @('plan', 'apply', 'rollback', 'runs', 'status')) {
            $r = Invoke-TestLabCapture $t @($w, 'observe')
            $r.Code | Should -Be 40
            $r.Err | Should -Match "'$w' is not a phase\."
            $r.Err | Should -Not -Match 'Did you mean'
        }
    }

    It 'the old options are plain mistakes' {
        foreach ($o in @('-Apply', '-ProfileName', '-Confirm')) {
            $r = Invoke-TestLabCapture $t @($o, 'x', 'observe')
            $r.Code | Should -Be 40
            $r.Err | Should -Match 'unknown option'
        }
    }

    It 'nothing is created by a usage error, help or the version' {
        foreach ($a in @('obsrve', '-h', '-V', '/?')) { Invoke-TestLabCapture $t @('-Root', $t.Root, $a) | Out-Null }
        Invoke-TestLabCapture $t @('-h', 'bogus', '-Root', $t.Root) | Out-Null
        Invoke-TestLabCapture $t @('-u', '4f2a', '-Root', $t.Root, '-Bogus') | Out-Null
        $t.Root | Should -Not -Exist
    }

    It 'a warning about an unused option never comes before an error' {
        $r = Invoke-TestLabCapture $t @('-BreakGlass', 'root', '-Root', 'relative', 'observe')
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'full path'
        $r.Err | Should -Not -Match 'warning'
    }

    It 'a warning about an unused option never comes before a run-time error' {
        $r = Invoke-TestLabCapture $t @('observe', '-BreakGlass', 'root', '-Root', $t.Root, '-Config', (Join-Path $t.Etc 'missing'))
        $r.Code | Should -Be 40
        $r.Err | Should -Match 'does not exist'
        $r.Err | Should -Not -Match 'warning'
        $r = Invoke-TestLabCapture $t @('-k', '4f2a', '-Profile', 'test', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Err | Should -Match "no run ending in '4f2a'"
        $r.Err | Should -Not -Match 'warning'
    }

    It '-u with no run, not as an Administrator, says who can list the runs' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        $r = Invoke-TestLabCapture $t @('-u', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("As Administrator, '$($t.Self) -History' lists them."))
    }

    It '-k with no run, not as an Administrator, says who can list the runs' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        $r = Invoke-TestLabCapture $t @('-k', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("As Administrator, '$($t.Self) -History' lists them."))
    }

    It 'the short letters are case-sensitive and the long names are not' {
        (Invoke-TestLabCapture $t @('-P', 'test', '-Root', $t.Root, '-Config', $t.Etc, 'observe')).Code | Should -Be 10
        (Invoke-TestLabCapture $t @('-p', 'test', 'observe')).Code | Should -Be 40
        (Invoke-TestLabCapture $t @('--PROFILE', 'test', '--Root', $t.Root, '--CONFIG', $t.Etc, 'observe')).Code | Should -Be 10
        (Invoke-TestLabCapture $t @('-profile', 'test', '-root', $t.Root, '-config', $t.Etc, 'observe')).Code | Should -Be 10
    }

    It '-r may come before or after the phase' {
        foreach ($argv in @(@('observe', '-r'), @('-r', 'observe'), @('-Run', 'observe'), @('observe', '--run'))) {
            $r = Invoke-TestLabCapture $t ($argv + @('-Root', $t.Root, '-Config', $t.Etc))
            $r.Err | Should -Not -Match 'unknown'
            $r.Err | Should -Not -Match 'is not a phase'
        }
    }

    It 'a value may follow an equals sign, a colon or a space' {
        foreach ($argv in @(@('-k=4f2a'), @('--keep=4f2a'), @('-Keep:4f2a'), @('-Keep', '4f2a'), @('-k', '4f2a'))) {
            $r = Invoke-TestLabCapture $t ($argv + @('-Root', $t.Root, '-Config', $t.Etc))
            $r.Err | Should -Match "no run ending in '4f2a'"
        }
    }

    It 'a Windows path with forward slashes is accepted' {
        $r = Invoke-TestLabCapture $t @('observe', '-Profile', 'test', '-Root', $t.Root.Replace('\', '/'), '-Config', $t.Etc.Replace('\', '/'))
        $r.Code | Should -Be 10
        $r.Err | Should -Not -Match 'full path'
    }

    It 'a run ID PowerShell reads as a number keeps its digits, leading zero included' {
        foreach ($flag in @('-k', '-u')) {
            $o = "-Root '$($t.Root)' -Config '$($t.Etc)'"
            $line = "& '$(Join-Path $t.Lab 'labyrinth.ps1')' $flag 0123 $o; exit `$LASTEXITCODE"
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
            (@($out) | ForEach-Object { "$_" }) -join "`n" | Should -Match "no run ending in '0123'"
        }
    }

    It 'a four-digit run ID PowerShell read as a number is still the ID' {
        $line = "& '$(Join-Path $t.Lab 'labyrinth.ps1')' -k 1234 -Root '$($t.Root)' -Config '$($t.Etc)'; exit `$LASTEXITCODE"
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $line 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        $code | Should -Be 40
        (@($out) | ForEach-Object { "$_" }) -join "`n" | Should -Match "no run ending in '1234'"
    }

    It '-p gets the case-slip hint for -P, and -v says it is planned, not a slip for -V' {
        $r = Invoke-TestLabCapture $t @('-p')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("unknown option '-p' (did you mean '-P', the profile?)"))
        $r.Err | Should -Not -Match 'At line:|Exception|CategoryInfo'
        $r = Invoke-TestLabCapture $t @('-v')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("'-v' (-Verbose) is planned and not built yet"))
        $r.Err | Should -Match ([regex]::Escape("Try '$($t.Self) -h'."))
        $r.Err | Should -Not -Match 'did you mean|At line:|Exception|CategoryInfo'
    }

    It '-y and -NoRevert are refused where they would do nothing, by name' {
        $r = Invoke-TestLabCapture $t @('-u', '4f2a', '-y', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Out | Should -BeNullOrEmpty
        @($r.Err -split "`r?`n") | Should -Be @("$($t.Name): -y is only for -u ID -All: add -All, or leave out -y", "Try '$($t.Self) -u -h'.")
        $r = Invoke-TestLabCapture $t @('-y', 'observe')
        $r.Err | Should -Match ([regex]::Escape('-y is only for -u ID -All or -NewSeed, not a preview'))
        $r = Invoke-TestLabCapture $t @('-Yes')
        $r.Err | Should -Match ([regex]::Escape('-y is only for -u ID -All or -NewSeed, not the status'))
        $r = Invoke-TestLabCapture $t @('-r', 'observe', '-NoRevert', '-y')
        $r.Err | Should -Match ([regex]::Escape('-y is only for -u ID -All or -NewSeed, not -r'))
        $r = Invoke-TestLabCapture $t @('-NoRevert', '-Probe')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape('-NoRevert is only for -r, not -Probe'))
        $r.Err | Should -Not -Match 'At line:|Exception|CategoryInfo'
        $t.Root | Should -Not -Exist
    }
}
