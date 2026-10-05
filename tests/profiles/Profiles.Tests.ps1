# The shipped profiles (Conventions, section 2.3; Blueprint, section 6.3).
# A profile lists only modules the release ships, each one able to run on
# the profile's platform, and the appliance profile only manual-only ones.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

    # Get-LabYmlValue: the value of a top-level key in a module.yml.
    function Get-LabYmlValue {
        param([string]$Path, [string]$Key)
        foreach ($l in (Get-Content -LiteralPath $Path)) {
            if ($l -match ('^' + $Key + ':\s*(.*)$')) {
                return (($Matches[1] -replace '\s*#.*$', '').Trim())
            }
        }
        return ''
    }

    # Get-LabProfileProblem: one line per problem in <Root>\profiles\*.profile.
    function Get-LabProfileProblem {
        param([string]$Root)
        $problems = @()
        $files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'profiles') -Filter '*.profile' | Sort-Object Name)
        foreach ($f in $files) {
            $name = $f.BaseName
            $n = 0
            $seen = @{}
            foreach ($raw in (Get-Content -LiteralPath $f.FullName)) {
                $n++
                $line = ($raw -replace '#.*$', '').Trim()
                if ($line -eq '') { continue }
                if ($line -cnotmatch '^(lockout|observe|deceive|sustain)\.[a-z0-9_-]+$') {
                    $problems += "${name}:${n}: not a module id: $line"; continue
                }
                if ($seen.ContainsKey($line)) { $problems += "${name}:${n}: listed twice: $line"; continue }
                $seen[$line] = $true
                $parts = $line.Split('.', 2)
                $dir = Join-Path $Root ('phases\' + $parts[0] + '\modules\' + $parts[1])
                $yml = Join-Path $dir 'module.yml'
                if (-not (Test-Path -LiteralPath $yml)) { $problems += "${name}:${n}: no such module: $line"; continue }
                if ((Get-LabYmlValue $yml 'id') -ne $line) { $problems += "${name}:${n}: its module.yml has another id: $line" }
                $plats = Get-LabYmlValue $yml 'platforms'
                if ($name -like 'windows-*') {
                    if ($plats -notmatch 'windows' -or -not (Get-ChildItem -LiteralPath $dir -Filter '*.ps1')) {
                        $problems += "${name}:${n}: does not run on Windows: $line"
                    }
                } elseif ($name -like 'linux-*') {
                    if (($plats -replace 'windows', '') -notmatch '[a-z]' -or -not (Get-ChildItem -LiteralPath $dir -Filter '*.sh')) {
                        $problems += "${name}:${n}: does not run on Linux: $line"
                    }
                } elseif ($name -eq 'appliance') {
                    if ((Get-LabYmlValue $yml 'risk') -ne 'manual-only') {
                        $problems += "${name}:${n}: not manual-only: $line"
                    }
                }
            }
        }
        return , $problems
    }
}

Describe 'Shipped profiles' {
    It 'the six profiles ship' {
        foreach ($name in 'linux-server', 'linux-web', 'linux-siem', 'windows-member', 'windows-dc', 'appliance') {
            Join-Path $script:Repo "profiles\$name.profile" | Should -Exist
        }
    }

    It 'every shipped profile lists only shipped modules that fit it' {
        $problems = Get-LabProfileProblem $script:Repo
        $problems.Count | Should -Be 0
    }

    It 'the check finds each kind of wrong line' {
        $t = Join-Path $TestDrive 'tree'
        $lin = Join-Path $t 'phases\lockout\modules\lin'
        $win = Join-Path $t 'phases\lockout\modules\win'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $t 'profiles'), $lin, $win
        Set-Content -LiteralPath (Join-Path $lin 'module.yml') -Value 'id: lockout.lin', 'platforms: [ubuntu]', 'risk: reversible'
        Set-Content -LiteralPath (Join-Path $lin 'check.sh') -Value ''
        Set-Content -LiteralPath (Join-Path $win 'module.yml') -Value 'id: lockout.win', 'platforms: [windows]', 'risk: manual-only'
        Set-Content -LiteralPath (Join-Path $win 'check.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $t 'profiles\linux-server.profile') -Value '# comment', '', 'lockout.lin', 'lockout.lin', 'Not An Id', 'lockout.gone', 'lockout.win # wrong platform'
        Set-Content -LiteralPath (Join-Path $t 'profiles\windows-member.profile') -Value 'lockout.win', 'lockout.lin'
        Set-Content -LiteralPath (Join-Path $t 'profiles\appliance.profile') -Value 'lockout.win', 'lockout.lin'
        $problems = Get-LabProfileProblem $t
        $problems | Should -Be @(
            'appliance:2: not manual-only: lockout.lin',
            'linux-server:4: listed twice: lockout.lin',
            'linux-server:5: not a module id: Not An Id',
            'linux-server:6: no such module: lockout.gone',
            'linux-server:7: does not run on Linux: lockout.win',
            'windows-member:2: does not run on Windows: lockout.lin'
        )
    }
}
