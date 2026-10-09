#Requires -Version 5.1
# Pester 5 unit tests for the release check (core\safety\Release.ps1,
# design 07, section 5.1).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $script:Repo 'core\safety\Release.ps1')

    function Write-TestFile {
        param([string] $Path, [string] $Text)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        [IO.File]::WriteAllText($Path, $Text)
    }
}

Describe 'the release check' {
    BeforeEach {
        $r = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        Write-TestFile (Join-Path $r 'labyrinth.ps1') "runner`n"
        Write-TestFile (Join-Path $r 'core\Lab.ps1') "lib`n"
        Write-TestFile (Join-Path $r 'phases\observe\modules\a\module.yml') "id: observe.a`n"
        Write-TestFile (Join-Path $r 'profiles\x.profile') "observe.a`n"
        Write-TestFile (Join-Path $r 'docs\notes.md') "not covered`n"
        $list = Join-Path $r 'release.sha256'
    }

    It 'the written list checks, and its hash is the list''s SHA-256' {
        $sum = Write-LabRelease -Root $r
        $sum | Should -MatchExactly '^[0-9a-f]{64}$'
        $sum | Should -Be (Get-FileHash -LiteralPath $list -Algorithm SHA256).Hash.ToLowerInvariant()
        $c = Test-LabRelease -Root $r
        $c.Status | Should -Be 'ok'
        $c.Hash | Should -Be $sum
        $text = [IO.File]::ReadAllText($list)
        $text | Should -Not -Match "`r"
        $text | Should -Match '(?m)^[0-9a-f]{64}  core/Lab\.ps1$'
        $text | Should -Not -Match 'docs/'
    }

    It 'no list is reported as missing, not as a problem' {
        $c = Test-LabRelease -Root $r
        $c.Status | Should -Be 'missing'
        $c.Problem | Should -Be ''
    }

    It 'a changed core file is refused, naming the file' {
        $null = Write-LabRelease -Root $r
        Write-TestFile (Join-Path $r 'core\Lab.ps1') "lib`nextra line`n"
        $c = Test-LabRelease -Root $r
        $c.Status | Should -Be 'problem'
        $c.Problem | Should -BeExactly 'core/Lab.ps1 differs from the release'
    }

    It 'a file planted under a covered folder is refused' {
        $null = Write-LabRelease -Root $r
        Write-TestFile (Join-Path $r 'phases\observe\modules\a\apply.ps1') "x`n"
        (Test-LabRelease -Root $r).Problem | Should -BeExactly 'phases/observe/modules/a/apply.ps1 is not in the release'
    }

    It 'a file outside the covered folders is not checked' {
        $null = Write-LabRelease -Root $r
        Write-TestFile (Join-Path $r 'docs\notes.md') "changed`n"
        Write-TestFile (Join-Path $r 'NOT_ADMIN') "x`n"
        (Test-LabRelease -Root $r).Status | Should -Be 'ok'
    }

    It 'a listed file that is missing is refused' {
        $null = Write-LabRelease -Root $r
        Move-Item -LiteralPath (Join-Path $r 'profiles\x.profile') -Destination (Join-Path $TestDrive 'x.profile') -Force
        (Test-LabRelease -Root $r).Problem | Should -BeExactly 'profiles/x.profile is missing, or is not a plain file'
    }

    It 'a malformed, empty or escaping list is refused' {
        [IO.File]::WriteAllText($list, "not a line`n")
        (Test-LabRelease -Root $r).Problem | Should -BeExactly "line 1 of release.sha256 is not '<sha256>  <path>'"
        [IO.File]::WriteAllText($list, '')
        (Test-LabRelease -Root $r).Problem | Should -BeExactly 'release.sha256 lists no files'
        $h = '0' * 64
        foreach ($path in @('../etc/passwd', 'core/../../x', 'core//Lab.ps1', './core/Lab.ps1', '/etc/passwd')) {
            [IO.File]::WriteAllText($list, "$h  $path`n")
            (Test-LabRelease -Root $r).Problem | Should -BeLike 'line 1 of release.sha256 names a path outside*' -Because $path
        }
    }

    It 'a path listed twice, or a list with Windows line ends, is refused' {
        $null = Write-LabRelease -Root $r
        $first = ([IO.File]::ReadAllText($list) -split "`n")[0]
        [IO.File]::AppendAllText($list, "$first`n")
        (Test-LabRelease -Root $r).Problem | Should -BeLike 'release.sha256 lists * twice'
        $null = Write-LabRelease -Root $r
        [IO.File]::WriteAllText($list, [IO.File]::ReadAllText($list).Replace("`n", "`r`n"))
        (Test-LabRelease -Root $r).Problem | Should -BeExactly "line 1 of release.sha256 is not '<sha256>  <path>'"
    }

    It 'the list matches the one the Linux tool would write for the same files' {
        # Same format and order as sha256sum: lower-case hash, two spaces,
        # / between folders, sorted by byte.
        $null = Write-LabRelease -Root $r
        $paths = @([IO.File]::ReadAllText($list).TrimEnd("`n") -split "`n" | ForEach-Object { $_.Substring(66) })
        $paths | Should -Be @('core/Lab.ps1', 'labyrinth.ps1', 'phases/observe/modules/a/module.yml', 'profiles/x.profile')
    }

    It 'the tool writes the list and prints the hash to record' {
        $out = @(& (Join-Path $script:Repo 'tools\release\manifest.ps1') $r)
        $out[1] | Should -Be "Release: $((Get-FileHash -LiteralPath $list -Algorithm SHA256).Hash.ToLowerInvariant())"
        (Test-LabRelease -Root $r).Status | Should -Be 'ok'
    }
}
