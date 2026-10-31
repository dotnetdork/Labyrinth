#Requires -Version 5.1
# Pester 5 unit tests for the event seed (core\seed\Seed.ps1, design 16). The
# expected values are in seed-vectors.txt, which seed.bats reads too.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
    # The fields of each line of one kind in seed-vectors.txt.
    function Get-Vector {
        param([string] $Kind)
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'seed-vectors.txt'))) {
            $f = @($line -split '\s+' | Where-Object { $_ })
            if ($f.Count -gt 0 -and $f[0] -ceq $Kind) { , @($f[1..($f.Count - 1)]) }
        }
    }
    $script:Good = 'K7QM2XRP9D4VHT3NB8WC6FJZQM2EL92G'
}

Describe 'HMAC-SHA256' {
    It 'the RFC 4231 test cases give their published results' {
        $cases = @(Get-Vector hmac)
        $cases.Count | Should -Be 6
        foreach ($c in $cases) { Get-LabHmacSha256 $c[0] $c[1] | Should -BeExactly $c[2] }
    }

    It 'upper-case hex gives the same result' {
        Get-LabHmacSha256 '0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B0B' '4869205468657265' |
            Should -BeExactly 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7'
    }
}

Describe 'the event seed' {
    It 'each known seed passes its check, in any case and with or without dashes' {
        $seeds = @(Get-Vector seed)
        $seeds.Count | Should -Be 3
        foreach ($v in $seeds) {
            $s = $v[0]
            $plain = $s -replace '-', ''
            ConvertTo-LabSeed $s | Should -BeExactly $plain
            ConvertTo-LabSeed $s.ToLowerInvariant() | Should -BeExactly $plain
            ConvertTo-LabSeed $plain | Should -BeExactly $plain
            ConvertTo-LabSeed ('  ' + ($s -replace '-', ' ') + ' ') | Should -BeExactly $plain
        }
    }

    It 'the same seed gives the published values for each label' {
        $labels = @(Get-Vector label)
        $labels.Count | Should -Be 3
        foreach ($v in $labels) { Get-LabSeedHmac (ConvertTo-LabSeed $v[0]) $v[1] | Should -BeExactly $v[2] }
        $values = @(Get-Vector value)
        $values.Count | Should -Be 12
        foreach ($v in $values) {
            Get-LabSeedValue (ConvertTo-LabSeed $v[0]) $v[1] ([long]$v[2]) ([long]$v[3]) | Should -Be ([long]$v[4])
        }
    }

    It 'a different seed or label gives a different value' {
        $a = ConvertTo-LabSeed 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
        $b = ConvertTo-LabSeed '2345-6789-ABCD-EFGH-JKLM-NPQR-STUV-JLNP'
        Get-LabSeedHmac $a 'decoy-port:1' | Should -Not -Be (Get-LabSeedHmac $b 'decoy-port:1')
        Get-LabSeedHmac $a 'decoy-port:1' | Should -Not -Be (Get-LabSeedHmac $a 'decoy-port:2')
    }

    It 'a typo anywhere fails the check group, and the message never repeats the seed' {
        for ($i = 0; $i -lt 32; $i++) {
            $c = '2'
            if ($Good[$i] -eq '2') { $c = '3' }
            $bad = $Good.Substring(0, $i) + $c + $Good.Substring($i + 1)
            $msg = ''
            try { ConvertTo-LabSeed $bad; throw 'accepted' } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*check group does not match*'
            $msg | Should -Not -BeLike "*$($bad.Substring(0, 8))*"
        }
    }

    It 'two neighbouring characters swapped fail the check group' {
        { ConvertTo-LabSeed 'K7QM-X2RP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G' } | Should -Throw '*check group*'
    }

    It 'the wrong length, a lookalike or an empty seed is refused with a reason' {
        { ConvertTo-LabSeed 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E' } | Should -Throw '*has 28*'
        { ConvertTo-LabSeed 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92GA' } | Should -Throw '*has 33*'
        foreach ($c in '0', '1', 'I', 'O', '#', '=') {
            { ConvertTo-LabSeed "K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92$c" } | Should -Throw '*other character*'
        }
        { ConvertTo-LabSeed '' } | Should -Throw '*no seed*'
    }

    It 'new: a seed is 8 groups of 4 from the alphabet, passes its own check and is never repeated' {
        $seen = @{}
        foreach ($i in 1..20) {
            $s = Get-LabRandomSeed
            $s | Should -MatchExactly '^[2-9A-HJ-NP-Z]{4}(-[2-9A-HJ-NP-Z]{4}){7}$'
            { ConvertTo-LabSeed $s } | Should -Not -Throw
            $seen.ContainsKey($s) | Should -BeFalse
            $seen[$s] = $true
        }
    }

    It 'new: every letter of the alphabet turns up, so no letter is left out' {
        $all = -join @(1..30 | ForEach-Object { Get-LabRandomSeed })
        foreach ($ch in $LabSeedAlphabet.ToCharArray()) { $all.Contains([string]$ch) | Should -BeTrue }
    }

    It 'value: stays in range, and a range of one number gives that number' {
        $s = ConvertTo-LabSeed 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
        foreach ($i in 1..8) {
            $v = Get-LabSeedValue $s "decoy-port:$i" 20000 20009
            $v | Should -BeGreaterOrEqual 20000
            $v | Should -BeLessOrEqual 20009
        }
        Get-LabSeedValue $s 'decoy-user:1' 7 7 | Should -Be 7
    }

    It 'value: an empty or too large range is refused' {
        $s = ConvertTo-LabSeed 'K7QM-2XRP-9D4V-HT3N-B8WC-6FJZ-QM2E-L92G'
        { Get-LabSeedValue $s 'decoy-port:1' 10 9 } | Should -Throw '*empty or too large*'
        { Get-LabSeedValue $s 'decoy-port:1' 0 2147483648 } | Should -Throw '*empty or too large*'
    }
}
