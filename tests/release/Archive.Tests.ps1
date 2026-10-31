#Requires -Version 5.1
# Pester 5 acceptance tests for the Windows release archive (design 21,
# sections 5.2 and 6): a release folder zipped and unpacked with the host's
# own tools still passes the release check with the same hash; an archive
# that changes by one byte no longer has the same SHA-256; and the manual's
# Windows steps compare the archive's hash before they unpack it, using only
# PowerShell's own commands. The Linux half is tests\release\archive.bats.
#
# That a mismatching archive is stopped before it is unpacked is a step the
# operator takes by eye, so what is tested here is that the hash differs and
# that the manual puts the comparison first.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:HostExe = (Get-Process -Id $PID).Path
    . (Join-Path $script:Repo 'core\safety\Release.ps1')

    function Write-TestFile {
        param([string] $Path, [string] $Text)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [IO.File]::WriteAllText($Path, $Text)
    }

    # Find-Step LINES PATTERN: the index of the first line that matches, or -1.
    function Find-Step {
        param([string[]] $Lines, [string] $Pattern)
        for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $Pattern) { return $i } }
        return -1
    }

    # Get-ManualWindowsText: the lines of the manual a Windows reader sees,
    # without the platform markers and the author comments.
    function Get-ManualWindowsText {
        $platform = ''
        $comment = $false
        foreach ($line in [IO.File]::ReadAllLines((Join-Path $script:Repo 'docs\manual\labyrinth.md'))) {
            if ($comment) { if ($line -eq '-->') { $comment = $false }; continue }
            if ($line -eq '<!--') { $comment = $true; continue }
            if ($line -eq '<!-- linux -->') { $platform = 'linux'; continue }
            if ($line -eq '<!-- windows -->') { $platform = 'windows'; continue }
            if ($line -eq '<!-- end -->') { $platform = ''; continue }
            if ($platform -ne 'linux') { $line }
        }
    }
}

Describe 'the Windows release archive' {
    BeforeEach {
        $tag = 'v0.0.0-test'
        $base = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $r = Join-Path $base "labyrinth-$tag"
        Write-TestFile (Join-Path $r 'labyrinth.ps1') "runner`n"
        Write-TestFile (Join-Path $r 'install.ps1') "installer`n"
        Write-TestFile (Join-Path $r 'core\Lab.ps1') "lib`n"
        Write-TestFile (Join-Path $r 'profiles\x.profile') "observe.a`n"
        Write-TestFile (Join-Path $r 'manual\about_Labyrinth.help.txt') "TOPIC`n"
        $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
            (Join-Path $script:Repo 'tools\release\manifest.ps1') $r
        # The grouped SHA-256 lines, joined back into one.
        $lines = @($out | ForEach-Object { "$_" })
        $at = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like 'SHA-256:  *' })[0]
        $sum = ($lines[$at].Substring(8) + $lines[$at + 1]) -replace ' ', ''
        $zip = Join-Path $base "labyrinth-$tag.zip"
        Compress-Archive -LiteralPath $r -DestinationPath $zip
    }

    It 'the manifest printed a SHA-256 for the offline record' {
        $sum | Should -MatchExactly '^[0-9a-f]{64}$'
    }

    It 'holds the release list and the manual, and unpacks to a folder that checks, with the same hash' {
        $dest = Join-Path $base 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $dest
        $u = Join-Path $dest "labyrinth-$tag"
        Join-Path $u 'release.sha256' | Should -Exist
        Join-Path $u 'manual\about_Labyrinth.help.txt' | Should -Exist
        $c = Test-LabRelease -Root $u
        $c.Status | Should -Be 'ok'
        $c.Hash | Should -Be $sum
    }

    It 'every file on the manifest checks with Get-FileHash, as the manual''s one-liner does' {
        $dest = Join-Path $base 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $dest
        Push-Location (Join-Path $dest "labyrinth-$tag")
        try {
            $bad = @(Get-Content .\release.sha256 | ForEach-Object {
                $h, $f = $_ -split '  ', 2
                if ((Get-FileHash $f).Hash -ne $h) { $f }
            })
        } finally { Pop-Location }
        $bad.Count | Should -Be 0
    }

    It 'an archive with one byte changed has a different SHA-256' {
        $bytes = [IO.File]::ReadAllBytes($zip)
        $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 1
        $copy = Join-Path $base 'copy.zip'
        [IO.File]::WriteAllBytes($copy, $bytes)
        (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash |
            Should -Not -Be (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    }
}

Describe 'the Windows manual''s steps to get the release' {
    BeforeAll {
        # From the line that starts the steps to the text after the installer's command.
        $steps = @()
        $on = $false
        foreach ($line in Get-ManualWindowsText) {
            if ($line -match '^\*\*Getting it onto a host\.') { $on = $true }
            if ($line -match '^It checks the release against') { $on = $false }
            if ($on) { $steps += $line }
        }
        $cmds = @()
        $inCode = $false
        foreach ($line in $steps) {
            if ($line -match '^```') { $inCode = -not $inCode; continue }
            if ($inCode -and $line.Trim() -ne '') { $cmds += $line }
        }
    }

    It 'are there' {
        $steps.Count | Should -BeGreaterThan 0
        $cmds.Count | Should -BeGreaterThan 0
    }

    It 'compare the archive with Get-FileHash before Expand-Archive, then check the list, then install' {
        $fetch = Find-Step $cmds '^Invoke-WebRequest -UseBasicParsing '
        $hash = Find-Step $cmds '^Get-FileHash "labyrinth-\$tag\.zip"$'
        $unpack = Find-Step $cmds '^Expand-Archive '
        $check = Find-Step $cmds 'Get-Content \.\\release\.sha256'
        $install = Find-Step $cmds '^\.\\install\.ps1$'
        $tls = Find-Step $cmds "SecurityProtocol = 'Tls12'"
        $tls | Should -BeGreaterOrEqual 0
        $tls | Should -BeLessThan $fetch
        $fetch | Should -BeGreaterOrEqual 0
        $hash | Should -BeGreaterThan $fetch
        $unpack | Should -BeGreaterThan $hash
        $check | Should -BeGreaterThan $unpack
        # The installer's own command comes after the file check, in the installer paragraph.
        $steps -join "`n" | Should -Match '(?m)^\.\\install\.ps1$'
        $install | Should -BeGreaterThan $check
    }

    It 'use no Invoke-Expression, iex or pipe into a shell, and no other download tool' {
        ($steps -join "`n") | Should -Not -Match '(?i)Invoke-Expression|(^|[^\w-])iex([^\w-]|$)|\|\s*(powershell|pwsh|cmd|bash|sh)\b'
        ($cmds -join "`n") | Should -Not -Match '(?i)curl|wget|bitsadmin|Start-BitsTransfer|certutil'
    }
}
