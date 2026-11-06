#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 --complete WORD...: the hidden entry that
# tab completion calls (docs\Conventions.md section 3.1, Tab completion), and
# the Labyrinth module that calls it. Mirrors complete.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Assert-TestList ACTUAL EXPECTED: the two lists are the same, in order.
    function Assert-TestList {
        param($Actual, $Expected)
        (@($Actual) -join '|') | Should -Be (@($Expected) -join '|')
    }

    # Get-TestComp T WORD...: the candidates for the last WORD, with the
    # test's data root and configuration folder on the line.
    function Get-TestComp {
        param($T, [string[]] $Word)
        $r = Invoke-TestLabCapture $T (@('--complete', '-Root', $T.Root, '-Config', $T.Etc) + $Word)
        $r.Code | Should -Be 0
        $r.Err | Should -BeNullOrEmpty
        return , @($r.Out -split '\r?\n' | Where-Object { $_ -ne '' })
    }

    # Get-TestBare WORD...: the same without a data root on the line.
    function Get-TestBare {
        param($T, [string[]] $Word)
        $r = Invoke-TestLabCapture $T (@('--complete') + $Word)
        $r.Code | Should -Be 0
        $r.Err | Should -BeNullOrEmpty
        return , @($r.Out -split '\r?\n' | Where-Object { $_ -ne '' })
    }

    # Write-TestRun T ID: a run on this host.
    function Write-TestRun {
        param($T, [string] $Id)
        $dir = Join-Path $T.Root "state\runs\$Id"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $dir 'manifest.jsonl') -Force | Out-Null
    }

    # Get-TestSnapshot T: every path of the test trees with its size and
    # time, then every file's hash: equal before and after means nothing
    # was written.
    function Get-TestSnapshot {
        param($T)
        $items = @(Get-ChildItem -LiteralPath $T.Lab, $T.Root, $T.Etc -Recurse -Force |
                Sort-Object FullName)
        $rows = @($items | ForEach-Object { '{0} {1} {2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks })
        $hashes = @($items | Where-Object { -not $_.PSIsContainer } |
                ForEach-Object { '{0} {1}' -f $_.FullName, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        return ($rows + $hashes) -join "`n"
    }
}

Describe 'labyrinth.ps1 --complete' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        $inv = Join-Path $t.Lab 'phases\lockout\modules\inventory'
        New-Item -ItemType Directory -Path $inv -Force | Out-Null
        Copy-Item -Path (Join-Path $script:Repo 'tests\fixtures\modules\recorder\*') -Destination $inv -Recurse
        New-Item -ItemType Directory -Path (Join-Path $t.Root 'state') -Force | Out-Null
        $phases = @('lockout', 'observe', 'deceive', 'sustain')
    }

    It 'offers the actions and options, by their long names, after two dashes' {
        # PowerShell cannot hand a script a lone '-', so the completer sends '--'.
        $c = Get-TestBare $t @('--')
        foreach ($want in '-Run', '-Keep', '-Undo', '-Version', '-Help', '-Profile',
            '-History', '-Show', '-Probe', '-NewSeed', '-SeedCheck', '-Manual', '-Root', '-Config', '-Only', '-Skip') {
            $c | Should -Contain $want
        }
        $c | Should -Not -Contain '-All'
        $c | Should -Not -Contain '-NoRevert'
        $c | Should -Not -Contain '-Yes'
    }

    It 'offers the short letters for a single typed letter' {
        Assert-TestList (Get-TestBare $t @('-r')) (@('-r', '-Run', '-Root'))
    }

    It 'matches a typed name ignoring case and dashes' {
        Assert-TestList (Get-TestBare $t @('-h')) (@('-History', '-h', '-Help'))
        Assert-TestList (Get-TestBare $t @('-RU')) (@('-Run'))
        Assert-TestList (Get-TestBare $t @('-r', '-no-r')) (@('-NoRevert'))
        Assert-TestList (Get-TestBare $t @('--ru')) (@('-Run'))
    }

    It 'offers only the options that fit the action on the line' {
        $c = Get-TestBare $t @('-u', '4f2a', '--')
        $c | Should -Contain '-All'
        $c | Should -Contain '-Yes'
        $c | Should -Not -Contain '-Only'
        $c | Should -Not -Contain '-NewSeed'
        $c | Should -Not -Contain '-Undo'
        $c = Get-TestBare $t @('-r', 'lockout', '--')
        foreach ($want in '-NoRevert', '-Only', '-Skip', '-Profile', '-BreakGlass', '-ConfirmGroup', '-Approve') {
            $c | Should -Contain $want
        }
        $c | Should -Not -Contain '-All'
        $c = Get-TestBare $t @('lockout', '-Only', 'lockout.inventory', '--')
        $c | Should -Contain '-Profile'
        $c | Should -Not -Contain '-Skip'
        $c | Should -Not -Contain '-Only'
        $c | Should -Not -Contain '-History'
    }

    It 'does not offer an option twice' {
        $c = Get-TestBare $t @('-Root', 'x', '--')
        $c | Should -Not -Contain '-Root'
        $c | Should -Contain '-Config'
    }

    It 'lets -k, -u and -Show be left without an ID, so an option can follow' {
        Assert-TestList (Get-TestBare $t @('-k', '-r')) (@('-Root'))
    }

    It 'offers the phases and the actions with nothing typed, and the phases for a prefix' {
        $c = Get-TestBare $t @('')
        Assert-TestList $c[0..3] $phases
        $c | Should -Contain '-Run'
        $c | Should -Contain '-Manual'
        $c | Should -Not -Contain '-Root'
        Assert-TestList (Get-TestBare $t @('ob')) (@('observe'))
        Assert-TestList (Get-TestBare $t @('OB')) (@('observe'))
        (Get-TestBare $t @('observe', '')) | Should -BeNullOrEmpty
    }

    It 'offers the phases after -r, and nothing after another action' {
        Assert-TestList (Get-TestBare $t @('-r', '')) ($phases)
        Assert-TestList (Get-TestBare $t @('-r', 's')) (@('sustain'))
        Assert-TestList (Get-TestBare $t @('-r', '-P', 'test', '')) ($phases)
        (Get-TestBare $t @('lockout', '-r', '')) | Should -BeNullOrEmpty
        (Get-TestBare $t @('-k', '4f2a', '')) | Should -BeNullOrEmpty
        (Get-TestBare $t @('-History', '')) | Should -BeNullOrEmpty
    }

    It 'offers the profile names after -P, from the configuration folder and the release' {
        New-Item -ItemType Directory -Path (Join-Path $t.Etc 'profiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $t.Etc 'profiles\event.profile') -Value 'observe.toggle'
        Set-Content -LiteralPath (Join-Path $t.Etc 'profiles\test.profile') -Value 'observe.toggle'
        Assert-TestList (Get-TestComp $t @('-P', '')) (@('event', 'test'))
        Assert-TestList (Get-TestComp $t @('-Profile', 'e')) (@('event'))
        Assert-TestList (Get-TestComp $t @('-r', '-P', 'T')) (@('test'))
        (Get-TestComp $t @('-P', 'nomatch')) | Should -BeNullOrEmpty
    }

    It 'offers the run IDs after -k, -u and -Show, newest first, as their last 4 characters' {
        Write-TestRun $t '20261001T000000Z-aaaa'
        Write-TestRun $t '20261003T090000Z-9b1c'
        Write-TestRun $t '20261002T140301Z-4f2a'
        # A folder with no manifest is a plan's leftover, not a run.
        New-Item -ItemType Directory -Path (Join-Path $t.Root 'state\runs\20261004T000000Z-dead') | Out-Null
        foreach ($w in '-k', '-Keep', '-u', '-Undo', '-Show') {
            Assert-TestList (Get-TestComp $t @($w, '')) (@('9b1c', '4f2a', 'aaaa'))
        }
    }

    It 'offers a run whole when another run ends the same way' {
        Write-TestRun $t '20261001T000000Z-4f2a'
        Write-TestRun $t '20261002T140301Z-4f2a'
        Write-TestRun $t '20261003T090000Z-9b1c'
        Assert-TestList (Get-TestComp $t @('-k', '')) (@('9b1c', '20261002T140301Z-4f2a', '20261001T000000Z-4f2a'))
    }

    It 'matches whole IDs and the 4 characters of an unshared run for typed text' {
        Write-TestRun $t '20261002T140301Z-4f2a'
        Write-TestRun $t '20261003T090000Z-9b1c'
        Assert-TestList (Get-TestComp $t @('-k', '20261002')) (@('20261002T140301Z-4f2a'))
        Assert-TestList (Get-TestComp $t @('-u', '9b')) (@('9b1c'))
        (Get-TestComp $t @('-u', 'zz')) | Should -BeNullOrEmpty
    }

    It 'offers the topics after -h: actions, options, phases, basics and module IDs' {
        $c = Get-TestBare $t @('-h', '')
        foreach ($want in 'run', 'keep', 'undo', 'history', 'show', 'probe', 'new-seed', 'seed-check', 'version', 'manual',
            'all', 'profile', 'root', 'config', 'break-glass', 'confirm-group', 'approve', 'yes', 'no-revert', 'only',
            'skip', 'basics', 'lockout', 'observe', 'deceive', 'sustain', 'observe.toggle', 'lockout.inventory') {
            $c | Should -Contain $want
        }
        $c | Should -Not -Contain 'help'
        Assert-TestList (Get-TestBare $t @('-Help', 'und')) (@('undo'))
        Assert-TestList (Get-TestBare $t @('-h', 'lockout.')) (@('lockout.inventory'))
        (Get-TestBare $t @('-h', 'undo', '')) | Should -BeNullOrEmpty
    }

    It 'offers the module IDs of the phase on the line after -Only and -Skip' {
        Assert-TestList (Get-TestBare $t @('lockout', '-Only', '')) (@('lockout.inventory'))
        Assert-TestList (Get-TestBare $t @('-r', 'observe', '-Skip', 'observe.t')) (@('observe.toggle'))
        $c = Get-TestBare $t @('-Only', '')
        $c | Should -Contain 'lockout.inventory'
        $c | Should -Contain 'observe.toggle'
        (Get-TestBare $t @('observe', '-Only', 'lockout.')) | Should -BeNullOrEmpty
    }

    It 'completes a comma list one ID at a time and carries the list in each candidate' {
        $c = Get-TestBare $t @('observe', '-Only', 'observe.toggle,')
        $c | Should -Contain 'observe.toggle,observe.sample'
        $c | Should -Not -Contain 'observe.toggle,observe.toggle'
        Assert-TestList (Get-TestBare $t @('observe', '-Skip', 'observe.toggle,observe.sa')) (@('observe.toggle,observe.sample'))
    }

    It 'offers nothing after a lone --, for a value with a colon or equals sign, or for free text' {
        (Get-TestBare $t @('--', '')) | Should -BeNullOrEmpty
        (Get-TestBare $t @('-r', '--', '')) | Should -BeNullOrEmpty
        (Get-TestBare $t @('-Root=x')) | Should -BeNullOrEmpty
        foreach ($w in '-Root', '-Config', '-BreakGlass', '-ConfirmGroup', '-Approve') {
            (Get-TestBare $t @($w, '')) | Should -BeNullOrEmpty -Because $w
        }
    }

    It 'reads profiles and runs from the -Root and -Config on the line' {
        $other = Join-Path $t.Root '..\other'
        New-Item -ItemType Directory -Path (Join-Path $other 'state\runs\20261005T000000Z-c0de'), (Join-Path $other 'etc\profiles') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $other 'state\runs\20261005T000000Z-c0de\manifest.jsonl') | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'etc\profiles\elsewhere.profile') -Value 'observe.toggle'
        Assert-TestList (Get-TestBare $t @('-Root', $other, '-k', '')) (@('c0de'))
        Assert-TestList (Get-TestBare $t @('-Root', $other, '-P', '')) (@('elsewhere', 'test'))
        Assert-TestList (Get-TestBare $t @('-Config', (Join-Path $other 'etc'), '-P', '')) (@('elsewhere', 'test'))
    }

    It 'writes nothing, takes no lock and logs nothing' {
        Write-TestRun $t '20261003T090000Z-9b1c'
        $before = Get-TestSnapshot $t
        foreach ($w in '', '--', '-r', '-k', '-u', '-P', '-Only', '-h') {
            Get-TestComp $t @($w, '') | Out-Null
        }
        Get-TestComp $t @('-k', '') | Out-Null
        Get-TestComp $t @('-r', '-P', '') | Out-Null
        Get-TestComp $t @('-Only', 'observe.toggle,') | Out-Null
        Get-TestSnapshot $t | Should -Be $before
        Test-Path -LiteralPath (Join-Path $t.Root 'state\lock') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $t.Root 'logs') | Should -BeFalse
    }

    It 'prints only candidates: nothing on the error stream, and only plain text' {
        Write-TestRun $t '20261003T090000Z-9b1c'
        $r = Invoke-TestLabCapture $t @('--complete', '-Root', $t.Root, '-k', '')
        $r.Err | Should -BeNullOrEmpty
        $r.Out | Should -Be '9b1c'
        $r = Invoke-TestLabCapture $t @('--complete', '-h', '')
        $r.Err | Should -BeNullOrEmpty
        $r.Out | Should -Not -Match '\x1b'
        foreach ($l in ($r.Out -split '\r?\n')) { $l | Should -Match '^[A-Za-z0-9._,:-]+$' }
    }

    It 'gives no run IDs, and no error, for a data root that is missing' {
        $r = Invoke-TestLabCapture $t @('--complete', '-Root', (Join-Path $t.Root 'no-such-root'), '-k', '')
        $r.Code | Should -Be 0
        $r.Out | Should -BeNullOrEmpty
        $r.Err | Should -BeNullOrEmpty
    }

    It 'still offers the other candidates when the data root cannot be read' {
        $gone = Join-Path $t.Root 'no-such-root'
        $r = Invoke-TestLabCapture $t @('--complete', '-Root', $gone, '-r', '')
        Assert-TestList ($r.Out -split '\r?\n') $phases
        $r = Invoke-TestLabCapture $t @('--complete', '-Root', $gone, '-P', '')
        $r.Out | Should -Be 'test'
    }

    It 'runs with no release check and loads none of the core' {
        & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $script:Repo 'tools\release\manifest.ps1') -Folder $t.Lab 2>&1 | Out-Null
        Add-Content -LiteralPath (Join-Path $t.Lab 'core\Lab.ps1') -Value "New-Item -ItemType File -Path '$($t.Root)\ran' -Force | Out-Null"
        Assert-TestList (Get-TestBare $t @('-r', '')) ($phases)
        (Invoke-TestLabCapture $t @('-V')).Code | Should -Be 20
        Test-Path -LiteralPath (Join-Path $t.Root 'ran') | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $t.Lab 'core') -Recurse -Force
        Assert-TestList (Get-TestBare $t @('-r', '')) ($phases)
    }

    It 'is not an option: help does not list it, and it is not offered' {
        $r = Invoke-TestLabCapture $t @('-h')
        $r.Code | Should -Be 0
        $r.Out | Should -Not -Match 'complete'
        @($r.Out -split '\r?\n').Count | Should -BeLessOrEqual 24
        (Get-TestBare $t @('--')) | Should -Not -Contain '--complete'
        (Invoke-TestLabCapture $t @('lockout', '--complete')).Code | Should -Be 40
    }
}

Describe 'the Labyrinth tab completion module' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
        # A launcher folder on the PATH: a laby.cmd and, next to it, the runner.
        $bin = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bin | Out-Null
        Copy-Item -LiteralPath (Join-Path $t.Lab 'labyrinth.ps1') -Destination $bin
        Copy-Item -LiteralPath (Join-Path $t.Lab 'core') -Destination $bin -Recurse
        Copy-Item -LiteralPath (Join-Path $t.Lab 'phases') -Destination $bin -Recurse
        Copy-Item -LiteralPath (Join-Path $t.Lab 'profiles') -Destination $bin -Recurse
        Set-Content -LiteralPath (Join-Path $bin 'laby.cmd') -Value '@echo off' -Encoding Ascii
    }

    It 'completes a laby command line through TabExpansion2 in a fresh PowerShell' {
        $module = Join-Path $script:Repo 'core\completion\Labyrinth.psm1'
        $script = @"
`$env:PATH = '$bin;' + `$env:PATH
Import-Module '$module'
`$line = 'laby -r '
(TabExpansion2 -inputScript `$line -cursorColumn `$line.Length).CompletionMatches | ForEach-Object { `$_.CompletionText }
"@
        $file = Join-Path $TestDrive 'tab.ps1'
        Set-Content -LiteralPath $file -Value $script -Encoding Ascii
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:HostExe
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $file + '"'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        $null = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        @($out.Result -split '\r?\n' | Where-Object { $_ -ne '' }) | Should -Be @('lockout', 'observe', 'deceive', 'sustain')
    }

    It 'offers nothing of Labyrinth''s for a laby that is not Labyrinth''s launcher' {
        $module = Join-Path $script:Repo 'core\completion\Labyrinth.psm1'
        $other = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'laby.cmd') -Value '@echo off' -Encoding Ascii
        $script = @"
`$env:PATH = '$other;' + `$env:PATH
Import-Module '$module'
(Get-Command -Module Labyrinth | Measure-Object).Count
`$line = 'laby -r '
@((TabExpansion2 -inputScript `$line -cursorColumn `$line.Length).CompletionMatches | Where-Object { `$_.CompletionText -in 'lockout', 'observe', 'deceive', 'sustain' }).Count
"@
        $file = Join-Path $TestDrive 'tab2.ps1'
        Set-Content -LiteralPath $file -Value $script -Encoding Ascii
        $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $file 2>&1
        @($out | ForEach-Object { "$_" }) | Should -Be @('0', '0')
    }
}
