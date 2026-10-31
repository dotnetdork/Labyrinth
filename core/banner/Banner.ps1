#Requires -Version 5.1
# core/banner/Banner.ps1: the installer's screen (docs\Conventions.md
# section 3.3): the maze with the version, what Labyrinth is and the
# copyright notice under it, the warning box with the
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
$LabBannerWidth = 55   # columns of the maze and the warning box
$LabBannerInner = 53   # columns inside the warning box's walls
# What Labyrinth is, and the copyright notice, centred under the version.
$LabBannerAbout = @('Rapid first-minute hardening tool for Linux & Windows,',
    'with traps that log every attacker move as a tripwire.')
$LabBannerNotice = 'Copyright (c) 2026 Jay Sausa. See LICENSE.'

# The box lines, by name.
$LabBox = @{}
foreach ($pair in @(
        @('TL', 0x2554), @('TR', 0x2557), @('BL', 0x255A), @('BR', 0x255D), @('H', 0x2550), @('V', 0x2551),
        @('ML', 0x2560), @('MR', 0x2563), @('IH', 0x2500), @('VI', 0x2502),
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
    foreach ($k in 'TL', 'TR', 'BL', 'BR', 'H', 'V', 'ML', 'MR', 'IH', 'VI', 'Mid', 'Last') { $all += $LabBox[$k] }
    return (Test-LabBannerText $all)
}

# Get-LabBannerCenter TEXT: TEXT centred in the box's inner width.
function Get-LabBannerCenter {
    param([string] $Text)
    $left = [int][Math]::Floor(($LabBannerInner - $Text.Length) / 2)
    return (' ' * $left) + $Text + (' ' * ($LabBannerInner - $Text.Length - $left))
}

# Get-LabBanner UNICODE VERSION SHA: the maze, the version line, what
# Labyrinth is, the copyright notice and the warning box, as lines. SHA empty
# means the copy has no release.sha256.
function Get-LabBanner {
    param([bool] $Unicode, [string] $Version, [AllowEmptyString()] [string] $Sha)
    $b = @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; ML = '+'; MR = '+' }
    if ($Unicode) { foreach ($k in @($b.Keys)) { $b[$k] = $LabBox[$k] } }
    $lines = @(Get-LabBannerMaze -Unicode $Unicode)
    $lines += "VERSION $Version ($LabBannerUrl)"
    $lines += ''
    foreach ($t in @($LabBannerAbout + '' + $LabBannerNotice + '')) {
        if ($t) { $t = (' ' * [Math]::Max(0, [int][Math]::Ceiling(($LabBannerWidth - $t.Length) / 2))) + $t }
        $lines += $t
    }
    $rule = $b.H * $LabBannerInner
    $lines += $b.TL + $rule + $b.TR
    $lines += $b.V + (Get-LabBannerCenter 'WARNING') + $b.V
    $lines += $b.ML + $rule + $b.MR
    if ($Sha) {
        $g = Get-LabReleaseGroup -Sha $Sha
        $body = @("If this SHA-256 doesn't match your", 'offline record, it was tampered with.', '', $g[0], $g[1])
    } else {
        $body = @('This copy has no release.sha256,', 'so nothing proves that it is genuine.')
    }
    foreach ($t in $body) { $lines += $b.V + (Get-LabBannerCenter $t) + $b.V }
    $lines += $b.BL + $rule + $b.BR
    return $lines
}

# Get-LabBannerTree UNICODE ARROW ROWS: the tree of changes to this host, as
# lines. Each row is @(label, text); ' -> ' in the text becomes an arrow
# when ARROW is set.
function Get-LabBannerTree {
    param([bool] $Unicode, [bool] $Arrow, [object[]] $Rows)
    $mid = '   |-- '
    $last = '   `-- '
    if ($Unicode) { $mid = "   $($LabBox.Mid)$($LabBox.IH)$($LabBox.IH) "; $last = "   $($LabBox.Last)$($LabBox.IH)$($LabBox.IH) " }
    $lines = @('  CHANGES TO THIS HOST')
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $text = [string] $Rows[$i][1]
        if ($Arrow) { $text = $text.Replace(' -> ', " $($LabBox.Arrow) ") }
        $lead = $mid
        if ($i -eq $Rows.Count - 1) { $lead = $last }
        $lines += $lead + ([string] $Rows[$i][0]).PadRight(10) + $text
    }
    return $lines
}

# Get-LabBannerList UNICODE HEADING ITEMS: a heading and a tree of items, as
# shown when the installer ends. An item may hold newlines; its later lines
# hang under its first.
function Get-LabBannerList {
    param([bool] $Unicode, [string] $Heading, [string[]] $Items)
    $lines = @("  $Heading")
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $isLast = $i -eq $Items.Count - 1
        if ($Unicode) {
            $lead = "   $($LabBox.Mid)$($LabBox.IH)$($LabBox.IH) "
            $cont = "   $($LabBox.VI)   "
            if ($isLast) { $lead = "   $($LabBox.Last)$($LabBox.IH)$($LabBox.IH) " }
        } else {
            $lead = '   |-- '
            $cont = '   |   '
            if ($isLast) { $lead = '   `-- ' }
        }
        if ($isLast) { $cont = '       ' }
        $first = $true
        foreach ($line in ($Items[$i] -split "`n")) {
            if ($first) { $lines += $lead + $line; $first = $false }
            else { $lines += $cont + $line }
        }
    }
    return $lines
}
