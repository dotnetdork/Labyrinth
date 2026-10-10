#Requires -Version 5.1
# core/safety/Release.ps1: the release check (design 07, section 5).
#
# release.sha256, in Labyrinth's folder, lists the SHA-256 of every file
# Labyrinth runs: one '<sha256>  <path>' line per file, the format of
# sha256sum, with the path relative to the folder and / between folders.
# It is made from the copy of the release that is deployed
# (tools\release\manifest.ps1). The team keeps the SHA-256 of
# release.sha256 itself in its offline record, and the operator compares
# it with the one Labyrinth prints.
#
# The runner loads this file on its own, before the rest of the core, so
# a changed core file is found before any of it runs. It needs nothing
# else from the core, and loading it changes nothing.
#
# The check cannot defend against an intruder who changes the runner or
# this file as well: they could print whatever hash was expected. The
# manual says how to check the release with the host's own tools instead.

# Get-LabReleaseSha FILE: the SHA-256 of FILE, in lower case.
function Get-LabReleaseSha {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Test-LabReleasePlain PATH: is PATH a file that is not a link?
function Test-LabReleasePlain {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Get-LabReleaseFile ROOT: the path under ROOT, with / between folders, of
# every file the release list covers, sorted, and of any linked folder
# among them, which is never a plain file. The list covers the runners and
# every file under core, phases, platform, profiles and vendor.
function Get-LabReleaseFile {
    param([Parameter(Mandatory)] [string] $Root)
    $LabReleaseFiles = @('labyrinth.sh', 'labyrinth.ps1')
    $LabReleaseDirs = @('core', 'phases', 'platform', 'profiles', 'vendor')
    $full = (Get-Item -LiteralPath $Root -Force).FullName.TrimEnd('\')
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($f in $LabReleaseFiles) {
        if (Test-Path -LiteralPath (Join-Path $full $f)) { $paths.Add($f) }
    }
    foreach ($d in $LabReleaseDirs) {
        $dir = Join-Path $full $d
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction Stop)) {
            $link = [bool] ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($item.PSIsContainer -and -not $link) { continue }
            $paths.Add($item.FullName.Substring($full.Length + 1).Replace('\', '/'))
        }
    }
    $sorted = $paths.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , $sorted
}

# Write-LabRelease ROOT: write ROOT\release.sha256 from the files under
# ROOT, with LF line ends, and return its SHA-256. Run at release time, on
# the copy that is deployed, never by the runner.
function Write-LabRelease {
    param([Parameter(Mandatory)] [string] $Root)
    $text = New-Object System.Text.StringBuilder
    foreach ($path in (Get-LabReleaseFile -Root $Root)) {
        $file = Join-Path $Root $path
        if ($path -cnotmatch '^[A-Za-z0-9._/-]+$' -or -not (Test-LabReleasePlain -Path $file)) {
            throw "release: not a plain file with a plain name: $path"
        }
        $null = $text.Append(('{0}  {1}' -f (Get-LabReleaseSha -Path $file), $path)).Append("`n")
    }
    $list = Join-Path $Root 'release.sha256'
    [IO.File]::WriteAllText($list, $text.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return Get-LabReleaseSha -Path $list
}

# Test-LabRelease ROOT: check every file under ROOT against
# ROOT\release.sha256. Returns an object with Status 'ok' (every file
# matches and none is missing or extra), 'missing' (there is no release
# list) or 'problem', the list's SHA-256 in Hash, and in Problem why the
# check failed.
function Test-LabRelease {
    param([Parameter(Mandatory)] [string] $Root)
    $r = [pscustomobject]@{ Status = 'problem'; Hash = ''; Problem = '' }
    $list = Join-Path $Root 'release.sha256'
    if (-not (Test-Path -LiteralPath $list)) { $r.Status = 'missing'; return $r }
    if (-not (Test-LabReleasePlain -Path $list)) { $r.Problem = 'release.sha256 is not a plain file'; return $r }
    try {
        $r.Hash = Get-LabReleaseSha -Path $list
        $text = [IO.File]::ReadAllText($list)
    } catch {
        $r.Problem = 'release.sha256 cannot be read'
        return $r
    }
    $lines = @()
    if ($text -ne '') { $lines = @($text -split "`n") }
    if ($text.EndsWith("`n")) { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    $listed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $n = 0
    foreach ($line in $lines) {
        $n++
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$') {
            $r.Problem = "line $n of release.sha256 is not '<sha256>  <path>'"
            return $r
        }
        $hash = $Matches[1]
        $path = $Matches[2]
        if ("/$path/" -match '/\.\./|/\./|//') {
            $r.Problem = "line $n of release.sha256 names a path outside Labyrinth's folder"
            return $r
        }
        if (-not $listed.Add($path)) { $r.Problem = "release.sha256 lists $path twice"; return $r }
        $file = Join-Path $Root $path
        if (-not (Test-LabReleasePlain -Path $file)) { $r.Problem = "$path is missing, or is not a plain file"; return $r }
        try { $h = Get-LabReleaseSha -Path $file } catch { $r.Problem = "$path cannot be read"; return $r }
        if ($h -cne $hash) { $r.Problem = "$path differs from the release"; return $r }
    }
    if ($n -eq 0) { $r.Problem = 'release.sha256 lists no files'; return $r }
    try { $files = Get-LabReleaseFile -Root $Root } catch { $r.Problem = "the files in $Root cannot be listed"; return $r }
    foreach ($path in $files) {
        if (-not $listed.Contains($path)) { $r.Problem = "$path is not in the release"; return $r }
    }
    $r.Status = 'ok'
    return $r
}
