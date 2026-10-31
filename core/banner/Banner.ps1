#Requires -Version 5.1
# core/banner/Banner.ps1: the installer's screen (docs\Conventions.md
# section 3.3): the maze with the version under it, the warning box with the
# release hash to compare by eye with the offline record, and the tree of
# changes. Needs core\safety\Release.ps1 (Get-LabReleaseGroup) and nothing
# else from the core; building it changes nothing.
#
# The maze is in maze.txt, drawn with box lines, and in maze-ascii.txt, drawn
# with + - and |, for a console that cannot show the box lines. No colour:
# many consoles and logs would show the escape codes instead. The box lines
# are built from their code points, as Windows PowerShell 5.1 reads a script
# file without a byte order mark as ANSI.

$LabBannerUrl = 'https://dotnetdork.github.io/Labyrinth/'
$LabBannerInner = 49   # columns inside the warning box's inner wall

# The box lines, by name.
$LabBox = @{}
foreach ($pair in @(
        @('TL', 0x2554), @('TR', 0x2557), @('BL', 0x255A), @('BR', 0x255D), @('H', 0x2550), @('V', 0x2551),
        @('ITL', 0x2553), @('ITR', 0x2556), @('IBL', 0x2559), @('IBR', 0x255C), @('IH', 0x2500),
        @('Mid', 0x251C), @('Last', 0x2514), @('Arrow', 0x2192))) {
    $LabBox[$pair[0]] = [string][char]$pair[1]
}

# Test-LabBannerText TEXT: can the console's output encoding write every
# character of TEXT?
function Test-LabBannerText {
    param([string] $Text)
    try {
        $enc = [Console]::OutputEncoding
        return $enc.GetString($enc.GetBytes($Text)) -ceq $Text
    } catch {
        return $false
    }
}

# Get-LabBannerMaze UNICODE: the maze's lines.
function Get-LabBannerMaze {
    param([bool] $Unicode)
    $name = 'maze-ascii.txt'
    if ($Unicode) { $name = 'maze.txt' }
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $name), [Text.Encoding]::UTF8)
    return @($text.Replace("`r", '').TrimEnd("`n") -split "`n")
}

# Test-LabBannerUnicode: can this console show the maze and the box lines?
function Test-LabBannerUnicode {
    $all = (Get-LabBannerMaze -Unicode $true) -join ''
    foreach ($k in 'TL', 'TR', 'BL', 'BR', 'H', 'V', 'ITL', 'ITR', 'IBL', 'IBR', 'IH', 'Mid', 'Last') { $all += $LabBox[$k] }
    return (Test-LabBannerText $all)
}

# Get-LabBannerCenter TEXT: TEXT centred in the box's inner width.
function Get-LabBannerCenter {
    param([string] $Text)
    $left = [int][Math]::Floor(($LabBannerInner - $Text.Length) / 2)
    return (' ' * $left) + $Text + (' ' * ($LabBannerInner - $Text.Length - $left))
}

# Get-LabBanner UNICODE VERSION SHA: the maze, the version line and the
# warning box, as lines. SHA empty means the copy has no release.sha256.
function Get-LabBanner {
    param([bool] $Unicode, [string] $Version, [AllowEmptyString()] [string] $Sha)
    $b = @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; ITL = '+'; ITR = '+'; IBL = '+'; IBR = '+'; IH = '-' }
    if ($Unicode) { foreach ($k in @($b.Keys)) { $b[$k] = $LabBox[$k] } }
    $lines = @(Get-LabBannerMaze -Unicode $Unicode)
    $lines += "VERSION $Version ($LabBannerUrl)"
    $lines += ''
    $lines += $b.TL + ($b.H * ($LabBannerInner + 4)) + $b.TR
    $lines += "$($b.V) $($b.ITL)" + ($b.IH * $LabBannerInner) + "$($b.ITR) $($b.V)"
    $body = @('', 'WARNING', '')
    if ($Sha) {
        $g = Get-LabReleaseGroup -Sha $Sha
        $body += @("If this SHA-256 doesn't match your", 'offline record, it was tampered with.', '', $g[0], $g[1], '')
    } else {
        $body += @('This copy has no release.sha256,', 'so nothing proves that it is genuine.', '')
    }
    foreach ($t in $body) { $lines += "$($b.V) $($b.V)" + (Get-LabBannerCenter $t) + "$($b.V) $($b.V)" }
    $lines += "$($b.V) $($b.IBL)" + ($b.IH * $LabBannerInner) + "$($b.IBR) $($b.V)"
    $lines += $b.BL + ($b.H * ($LabBannerInner + 4)) + $b.BR
    return $lines
}

# Get-LabBannerTree UNICODE ARROW ROWS: the tree of changes to this host, as
# lines. Each row is @(label, text); ' -> ' in the text becomes an arrow
# when ARROW is set.
function Get-LabBannerTree {
    param([bool] $Unicode, [bool] $Arrow, [object[]] $Rows)
    $mid = ' |-- '
    $last = ' `-- '
    if ($Unicode) { $mid = " $($LabBox.Mid)$($LabBox.IH)$($LabBox.IH) "; $last = " $($LabBox.Last)$($LabBox.IH)$($LabBox.IH) " }
    $lines = @('CHANGES TO THIS HOST')
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $text = [string] $Rows[$i][1]
        if ($Arrow) { $text = $text.Replace(' -> ', " $($LabBox.Arrow) ") }
        $lead = $mid
        if ($i -eq $Rows.Count - 1) { $lead = $last }
        $lines += $lead + ([string] $Rows[$i][0]).PadRight(10) + $text
    }
    return $lines
}
