script:Repo = (Resolve-Path (Join-Path $PSScriptRoot2 '..\..')).Path

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
    
