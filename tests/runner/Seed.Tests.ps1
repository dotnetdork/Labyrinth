#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -NewSeed and -SeedCheck (design 16,
# section 4.1; docs\Conventions.md section 3.1). Mirrors seed.bats. The
# console is a test double (tests\fixtures\Doubles.ps1): what the program
# writes there goes to tty.out in the test tree, and each line it reads is
# the next line of tty.in.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll and BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')
    $good = 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
    $other = '2345-6789-ABCD-EFGH-JKLM-NPQR-STUV-JLNP'
    $typo = 'L7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
    $seedShape = '^([2-9A-HJ-NP-Z]{4}-){7}[2-9A-HJ-NP-Z]{4}$'
    $thisHost = $script:ThisHost

    # Invoke-TestSeed T ARGS: labyrinth.ps1 with the test data root and
    # configuration folder.
    function Invoke-TestSeed {
        param($T, [string[]] $Arguments)
        Invoke-TestLabCapture $T (@($Arguments) + @('-Root', $T.Root, '-Config', $T.Etc))
    }

    # Write-TestTyped T LINES: the lines the operator types, in order. The
    # position is reset, so the lines are read from the first.
    function Write-TestTyped {
        param($T, [AllowEmptyString()] [string[]] $Lines)
        Remove-Item -LiteralPath (Join-Path $T.Lab 'tty.pos') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $T.Lab 'tty.out') -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText((Join-Path $T.Lab 'tty.in'), (($Lines | ForEach-Object { "$_`n" }) -join ''))
    }

    function Get-TestTtyOut {
        param($T)
        $f = Join-Path $T.Lab 'tty.out'
        if (Test-Path -LiteralPath $f) { return [IO.File]::ReadAllText($f) }
        return ''
    }

    # Get-TestStored T KEY: the value of KEY in seed.conf, or ''.
    function Get-TestStored {
        param($T, [string] $Key)
        $f = Join-Path $T.Etc 'seed.conf'
        if (-not (Test-Path -LiteralPath $f)) { return '' }
        foreach ($l in @(Get-Content -LiteralPath $f)) {
            if ($l.StartsWith("$Key=", [StringComparison]::Ordinal)) { return $l.Substring($Key.Length + 1) }
        }
        return ''
    }

    function Write-TestSeedFile {
        param($T, [string[]] $Lines)
        [IO.File]::WriteAllText((Join-Path $T.Etc 'seed.conf'), (($Lines | ForEach-Object { "$_`n" }) -join ''))
    }
}

Describe 'labyrinth.ps1 -NewSeed' {
    BeforeEach {
        $t = Initialize-TestLab
        $seedFile = Join-Path $t.Etc 'seed.conf'
    }

    It 'needs an Administrator, and saves nothing without one' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        Write-TestTyped $t @('recorded')
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape('-NewSeed needs an elevated Administrator session'))
        $seedFile | Should -Not -Exist
        (Join-Path $t.Lab 'tty.out') | Should -Not -Exist
    }

    It 'needs a terminal, and saves nothing without one' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NO_TTY') | Out-Null
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape('-NewSeed needs a terminal to show the seed on'))
        $seedFile | Should -Not -Exist
        (Join-Path $t.Lab 'tty.out') | Should -Not -Exist
    }

    It 'needs the configuration folder' {
        Write-TestTyped $t @('recorded')
        $missing = Join-Path $TestDrive 'missing'
        $r = Invoke-TestLabCapture $t @('-NewSeed', '-Root', $t.Root, '-Config', $missing)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("the configuration folder does not exist: $missing"))
        $missing | Should -Not -Exist
    }

    It 'saves a valid seed and shows it only on the terminal' {
        Write-TestTyped $t @('recorded')
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 0
        $seed = Get-TestStored $t 'DECOY_SEED'
        $seed | Should -Match $seedShape
        # Only the trusted accounts can read it, whatever the folder passes down.
        $acl = Get-Acl -LiteralPath $seedFile
        $acl.AreAccessRulesProtected | Should -BeTrue
        $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
        # Administrators, SYSTEM and the account running it (Get-LabTrustedSid).
        $trusted = @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $sids.Count | Should -BeGreaterThan 0
        foreach ($sid in $sids) { $trusted | Should -Contain $sid }
        @($r.Out -split "`r?`n") | Should -Be @("Saved this host's decoy seed in $seedFile.", "Post it in the team chat with this host's name: $thisHost.")
        ($r.Out + $r.Err).Contains($seed) | Should -BeFalse
        ($r.Out + $r.Err).Contains($seed.Replace('-', '')) | Should -BeFalse
        $shown = Get-TestTtyOut $t
        $shown | Should -Match ([regex]::Escape("Decoy seed for $thisHost, shown once:"))
        $shown.Contains("      $seed") | Should -BeTrue
        $shown.Contains("Type 'recorded' once it is in the offline record and the team chat: ") | Should -BeTrue
        # It needs no hosts file: it is not a preview or a run.
        (Join-Path $t.Etc 'hosts') | Should -Not -Exist
        $t.Root | Should -Not -Exist
    }

    It 'makes a seed that passes -SeedCheck' {
        Write-TestTyped $t @('recorded')
        (Invoke-TestSeed $t @('-NewSeed')).Code | Should -Be 0
        Write-TestTyped $t @((Get-TestStored $t 'DECOY_SEED'))
        $r = Invoke-TestSeed $t @('-SeedCheck')
        $r.Code | Should -Be 0
        $r.Out | Should -BeExactly 'Valid seed: the check group matches.'
    }

    It 'keeps the other keys in seed.conf' {
        Write-TestSeedFile $t @("TEAM_SEED=$other")
        Write-TestTyped $t @('recorded')
        (Invoke-TestSeed $t @('-NewSeed')).Code | Should -Be 0
        Get-TestStored $t 'TEAM_SEED' | Should -BeExactly $other
        Get-TestStored $t 'DECOY_SEED' | Should -Match $seedShape
    }

    It 'asks before replacing a seed, and keeps the old one unless you say yes' {
        foreach ($a in @('n', '', 'no', 'maybe')) {
            Write-TestSeedFile $t @("DECOY_SEED=$good")
            Write-TestTyped $t @($a, 'recorded')
            $r = Invoke-TestSeed $t @('-NewSeed')
            $r.Code | Should -Be 0 -Because "answer '$a'"
            $r.Out | Should -BeExactly 'Nothing was changed.'
            Get-TestStored $t 'DECOY_SEED' | Should -BeExactly $good
            $shown = Get-TestTtyOut $t
            $shown.Contains("This host already has a decoy seed. Replace it? The decoys made from the`n") | Should -BeTrue
            $shown | Should -BeLike '*old one must be made again. `[y/N`] '
            $shown.Contains('Decoy seed for') | Should -BeFalse
        }
    }

    It 'replaces the seed when you answer yes' {
        foreach ($a in @('y', 'YES', 'yes')) {
            Write-TestSeedFile $t @("DECOY_SEED=$good")
            Write-TestTyped $t @($a, 'recorded')
            (Invoke-TestSeed $t @('-NewSeed')).Code | Should -Be 0 -Because "answer '$a'"
            Get-TestStored $t 'DECOY_SEED' | Should -Not -BeExactly $good
            Get-TestStored $t 'DECOY_SEED' | Should -Match $seedShape
            @(Get-Content -LiteralPath $seedFile | Where-Object { $_ -like 'DECOY_SEED=*' }).Count | Should -Be 1
        }
    }

    It '-y replaces the seed without asking' {
        Write-TestSeedFile $t @("DECOY_SEED=$good")
        Write-TestTyped $t @('recorded')
        (Invoke-TestSeed $t @('-NewSeed', '-y')).Code | Should -Be 0
        Get-TestStored $t 'DECOY_SEED' | Should -Not -BeExactly $good
        (Get-TestTtyOut $t).Contains('Replace it?') | Should -BeFalse
        Remove-Item -LiteralPath $seedFile -Force
        Write-TestTyped $t @('recorded')
        (Invoke-TestSeed $t @('-Yes', '-NewSeed')).Code | Should -Be 0
        Get-TestStored $t 'DECOY_SEED' | Should -Match $seedShape
    }

    It 'asks again for recorded until it is typed' {
        Write-TestTyped $t @('no', 'recorded')
        (Invoke-TestSeed $t @('-NewSeed')).Code | Should -Be 0
        Get-TestStored $t 'DECOY_SEED' | Should -Match $seedShape
    }

    It 'a console that goes before recorded leaves no new seed' {
        Write-TestSeedFile $t @("TEAM_SEED=$other")
        Remove-Item -LiteralPath (Join-Path $t.Lab 'tty.in') -Force -ErrorAction SilentlyContinue
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape('the seed was not recorded, so it was not saved'))
        Get-TestStored $t 'DECOY_SEED' | Should -BeNullOrEmpty
        Get-TestStored $t 'TEAM_SEED' | Should -BeExactly $other
        ($r.Out).Contains('Saved') | Should -BeFalse
    }

    It 'a console that goes before recorded puts the old seed back' {
        Write-TestSeedFile $t @("DECOY_SEED=$good", "TEAM_SEED=$other")
        Remove-Item -LiteralPath (Join-Path $t.Lab 'tty.in') -Force -ErrorAction SilentlyContinue
        $r = Invoke-TestSeed $t @('-NewSeed', '-y')
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape('the seed was not recorded, so it was not saved'))
        Get-TestStored $t 'DECOY_SEED' | Should -BeExactly $good
        Get-TestStored $t 'TEAM_SEED' | Should -BeExactly $other
        # Answering yes, then losing the console, restores it too.
        Write-TestTyped $t @('y')
        (Invoke-TestSeed $t @('-NewSeed')).Code | Should -Be 20
        Get-TestStored $t 'DECOY_SEED' | Should -BeExactly $good
    }

    It 'a seed.conf that is not valid is an error that names the file and never the seed' {
        Write-TestSeedFile $t @("DECOY_SEED=$typo")
        Write-TestTyped $t @('y', 'recorded')
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape($seedFile))
        ($r.Out + $r.Err).Contains($typo) | Should -BeFalse
        Get-TestStored $t 'DECOY_SEED' | Should -BeExactly $typo
        Write-TestSeedFile $t @('not a key line')
        Write-TestTyped $t @('recorded')
        $r = Invoke-TestSeed $t @('-NewSeed')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape($seedFile))
    }

    It 'takes no seed word, never repeats it, and -y is refused with other actions' {
        $word = 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
        foreach ($a in '-NewSeed', '-SeedCheck') {
            $r = Invoke-TestSeed $t @($a, $word)
            $r.Code | Should -Be 40
            $r.Err | Should -Match ([regex]::Escape('takes no seed on the command line: it asks for one'))
            $r.Err | Should -Match 'shell history'
            "$($r.Out)$($r.Err)" | Should -Not -Match 'K7QM'
        }
        $r = Invoke-TestSeed $t @('-SeedCheck', '-y')
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape('-y is only for -u ID -All or -NewSeed, not -SeedCheck'))
    }
}

Describe 'labyrinth.ps1 -SeedCheck' {
    BeforeEach {
        $t = Initialize-TestLab
    }

    It 'says a valid seed is valid, in any case and with or without dashes' {
        foreach ($s in @($good, $good.ToLowerInvariant(), $good.Replace('-', ''), $good.Replace('-', ' '))) {
            Write-TestTyped $t @($s)
            $r = Invoke-TestSeed $t @('-SeedCheck')
            $r.Code | Should -Be 0 -Because "'$s'"
            $r.Out | Should -BeExactly 'Valid seed: the check group matches.'
            (Get-TestTtyOut $t) | Should -BeExactly 'Seed to check: '
        }
    }

    It 'refuses a typo, exits 30, and never repeats what was typed' {
        Write-TestTyped $t @($typo)
        $r = Invoke-TestSeed $t @('-SeedCheck')
        $r.Code | Should -Be 30
        $r.Out | Should -Match ([regex]::Escape('the check group does not match'))
        $r.Out | Should -Match ([regex]::Escape('Check it against the offline record and type it again.'))
        ($r.Out + $r.Err).Contains($typo) | Should -BeFalse
        ($r.Out + $r.Err).Contains($typo.Replace('-', '')) | Should -BeFalse
        Write-TestTyped $t @('K7QM-2XRP')
        $r = Invoke-TestSeed $t @('-SeedCheck')
        $r.Code | Should -Be 30
        ($r.Out + $r.Err).Contains('K7QM-2XRP') | Should -BeFalse
        Write-TestTyped $t @('')
        (Invoke-TestSeed $t @('-SeedCheck')).Code | Should -Be 30
    }

    It 'needs a terminal, and does not read the seed from standard input' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NO_TTY') | Out-Null
        $r = Invoke-TestSeed $t @('-SeedCheck')
        $r.Code | Should -Be 20
        $r.Err | Should -Match ([regex]::Escape('-SeedCheck needs a terminal to type the seed at'))
        Remove-Item -LiteralPath (Join-Path $t.Lab 'NO_TTY') -Force
        $r = Invoke-TestLab $t @('-SeedCheck', '-Root', $t.Root, '-Config', $t.Etc) -Answers @($good)
        $r.Code | Should -Be 20
        $r.Output.Contains('Valid') | Should -BeFalse
    }

    It 'needs no Administrator, no configuration folder and no data root' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        Remove-Item -LiteralPath $t.Etc -Recurse -Force
        Write-TestTyped $t @($good)
        $r = Invoke-TestSeed $t @('-SeedCheck')
        $r.Code | Should -Be 0
        $r.Out | Should -BeExactly 'Valid seed: the check group matches.'
        $t.Root | Should -Not -Exist
        $t.Etc | Should -Not -Exist
    }
}
