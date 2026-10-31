#Requires -Version 5.1
# core/seed/Seed.ps1: the event seed (design 16). Dot-sourced through
# core/Lab.ps1.
#
# A seed is 28 random characters and a 4-character check group, written as
# 8 groups of 4, such as 3LES-4LLU-DG9M-GZ3C-DB9D-LL2D-5YVY-4G4N. The
# characters come from a 32-letter alphabet with no lookalikes (no 0, 1,
# I or O), so each is exactly 5 random bits: 140 bits in all. The check group
# is worked out from the other 28 by a public formula, so a typo is caught;
# it adds no secrecy. Case and dashes do not matter on input.
#
# Every value is HMAC-SHA256(key, "purpose:index"), the key being the 28
# random characters, then mapped into the range needed. The results are the
# same as core/seed/seed.sh's.
#
# Nothing here logs, records or stores a seed. Hold one in a variable and
# never pass it on a command line: another program's arguments can be read
# by any user on the host.

$LabSeedAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'

# ConvertTo-LabHex: bytes as lower-case hex, with nothing between them.
function ConvertTo-LabHex {
    param([byte[]] $Bytes)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# ConvertFrom-LabHex: the bytes a hex string spells.
function ConvertFrom-LabHex {
    param([AllowEmptyString()] [string] $Hex)
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return , $bytes
}

# Get-LabHmacSha256: HMAC-SHA256 (RFC 2104) of the message bytes under the
# key bytes, both given as hex; returns the result as hex.
function Get-LabHmacSha256 {
    param([AllowEmptyString()] [string] $KeyHex, [AllowEmptyString()] [string] $MessageHex)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, (ConvertFrom-LabHex $KeyHex))
    try { return (ConvertTo-LabHex $hmac.ComputeHash((ConvertFrom-LabHex $MessageHex))) }
    finally { $hmac.Dispose() }
}

# Get-LabSha256Hex: the SHA-256 of a string's ASCII bytes, as hex.
function Get-LabSha256Hex {
    param([string] $Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-LabHex $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

# Get-LabSeedCheck: the check group for the 28 random characters Body: the
# first 20 bits of SHA-256("labyrinth-seed-check:" Body), as 4 letters of
# the alphabet.
function Get-LabSeedCheck {
    param([string] $Body)
    $v = [Convert]::ToInt32((Get-LabSha256Hex "labyrinth-seed-check:$Body").Substring(0, 5), 16)
    return -join @(15, 10, 5, 0 | ForEach-Object { $LabSeedAlphabet[($v -shr $_) -band 31] })
}

# Format-LabSeed: the 32 characters of a seed as 8 groups of 4.
function Format-LabSeed {
    param([string] $Seed)
    return ((0..7 | ForEach-Object { $Seed.Substring($_ * 4, 4) }) -join '-')
}

# Get-LabRandomSeed: a new seed from the system's cryptographic random source, as
# 8 groups of 4. Each random byte gives its low 5 bits; 256 is 8 x 32, so
# every letter is equally likely.
function Get-LabRandomSeed {
    $bytes = New-Object byte[] 28
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $body = -join @($bytes | ForEach-Object { $LabSeedAlphabet[$_ -band 31] })
    [Array]::Clear($bytes, 0, $bytes.Length)
    return (Format-LabSeed ($body + (Get-LabSeedCheck $body)))
}

# ConvertTo-LabSeed: Text as a seed of 32 characters, upper case, with no
# dashes or spaces. Throws when Text is not a seed or its check group does
# not match. The message never repeats Text.
function ConvertTo-LabSeed {
    param([AllowEmptyString()] [string] $Text)
    $s = ($Text.ToUpperInvariant() -replace '[-\s]', '')
    if ($s -eq '') { throw 'seed: no seed given' }
    $bad = ($s -creplace "[$LabSeedAlphabet]", '')
    if ($bad -ne '') {
        throw "seed: a seed uses only 2-9 and the letters A-Z without I and O; this one has $($bad.Length) other character(s)"
    }
    if ($s.Length -ne 32) { throw "seed: a seed has 32 characters (8 groups of 4); this one has $($s.Length)" }
    if ((Get-LabSeedCheck $s.Substring(0, 28)) -cne $s.Substring(28, 4)) {
        throw 'seed: the check group does not match, so the seed has a typo'
    }
    return $s
}

# Get-LabSeedHmac: HMAC-SHA256 of Label (such as decoy-port:1) under the
# seed's 28 random characters, as hex. Seed must be normalized.
function Get-LabSeedHmac {
    param([string] $Seed, [string] $Label)
    $key = ConvertTo-LabHex ([Text.Encoding]::ASCII.GetBytes($Seed.Substring(0, 28)))
    return (Get-LabHmacSha256 $key (ConvertTo-LabHex ([Text.Encoding]::ASCII.GetBytes($Label))))
}

# Get-LabSeedValue: a whole number from Min to Max (at most 2^31 values), the
# same for the same seed and label on every host. It reads the HMAC 32 bits
# at a time and throws away a block at or above the largest multiple of the
# range's size, so every number is equally likely. If all 8 blocks are
# thrown away, it goes on with the HMAC of "Label#1", "Label#2" and so on.
function Get-LabSeedValue {
    param([string] $Seed, [string] $Label, [long] $Min, [long] $Max)
    $n = $Max - $Min + 1
    if ($n -lt 1 -or $n -gt 2147483648) { throw "seed: the range $Min to $Max is empty or too large" }
    $limit = [long][Math]::Floor(4294967296 / $n) * $n
    $round = 0
    while ($true) {
        $l = $Label
        if ($round -gt 0) { $l = "$Label#$round" }
        $h = Get-LabSeedHmac $Seed $l
        for ($i = 0; $i -lt 64; $i += 8) {
            $v = [Convert]::ToInt64($h.Substring($i, 8), 16)
            if ($v -lt $limit) { return ($Min + $v % $n) }
        }
        $round++
    }
}

# The seed file, <root>\etc\seed.conf: KEY=value lines, written by Labyrinth
# and never copied between hosts. It inherits the data root's permissions,
# Administrators and SYSTEM only. DECOY_SEED is this host's own seed for its
# decoys; TEAM_SEED (design 04) is the same on every host. It is kept apart
# from event.conf, which is copied between hosts, so copying that can never
# copy a seed.
function Get-LabSeedFile { return (Join-Path $env:LAB_CONFIG_DIR 'seed.conf') }

# Read-LabSeed: the seed stored under Key, normalized, or $null when there is
# none. Throws when the file cannot be read, has a line that is not
# KEY=value, or the stored seed is not valid.
function Read-LabSeed {
    param([string] $Key)
    $file = Get-LabSeedFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $val = $null
    foreach ($l in @(Get-LabConfigLine $file)) {
        if ($l.Text -cnotmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { throw "${file}:$($l.No): expected KEY=value" }
        if ($Matches[1] -ceq $Key) { $val = $Matches[2].Trim() }
    }
    if (-not $val) { return $null }
    try { return (ConvertTo-LabSeed $val) } catch { throw "${file}: $Key is not a valid seed" }
}

# Save-LabSeed: write Seed under Key in the seed file, keeping the file's
# other keys; with no Seed, remove Key. The file is written whole to a new
# file in the same folder, then moved into place.
function Save-LabSeed {
    param([string] $Key, [AllowEmptyString()] [string] $Seed = '')
    $file = Get-LabSeedFile
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Seeds for this host only (design 16). Written by Labyrinth: never copy')
    $lines.Add('# this file to another host, and never commit it.')
    if (Test-Path -LiteralPath $file) {
        foreach ($l in @(Get-LabConfigLine $file)) {
            if (-not $l.Text.StartsWith("$Key=", [StringComparison]::Ordinal)) { $lines.Add($l.Text) }
        }
    }
    if ($Seed) { $lines.Add("$Key=$(Format-LabSeed $Seed)") }
    $tmp = "$file.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        # Made empty and given an access list for the trusted accounts only
        # (Get-LabTrustedSid) before the seed is written, whatever the folder
        # passes down, as chmod 600 does on Linux. Writing and moving keep it.
        $sec = New-Object Security.AccessControl.FileSecurity
        $sec.SetAccessRuleProtection($true, $false)
        foreach ($sid in @(Get-LabTrustedSid)) {
            $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                        (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'Allow')))
        }
        [IO.File]::WriteAllText($tmp, '')
        (Get-Item -LiteralPath $tmp -Force).SetAccessControl($sec)
        [IO.File]::WriteAllText($tmp, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# Show-LabSeed: show Seed once on the console, wait until the operator types
# 'recorded', then clear it from the screen, as a new password is shown
# (Show-LabSecret). Label is the host's name. Returns 0 once recorded, 20
# when there is no console, and 1 when the console goes before the answer:
# the caller must then undo what it saved, because nobody recorded the seed.
function Show-LabSeed {
    param([string] $Label, [string] $Seed)
    if (-not (Test-LabTerminal)) {
        [Console]::Error.WriteLine('seed: no terminal to show the seed on')
        return 20
    }
    $row = Get-LabTerminalRow
    Write-LabTerminal ("`r`n  Decoy seed for $Label, shown once:`r`n`r`n      $Seed`r`n`r`n")
    while ($true) {
        Write-LabTerminal "  Type 'recorded' once it is in the offline record and the team chat: "
        $answer = Read-LabTerminal
        if ($null -eq $answer) {
            Write-LabTerminal "`r`n"
            return 1
        }
        if ($answer.Trim() -eq 'recorded') { break }
    }
    Clear-LabTerminal -Row $row
    return 0
}
