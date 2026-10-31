#Requires -Version 5.1
# Pester 5 tests for install.ps1, the guided installer for Windows
# (docs\Conventions.md section 3.3), for the launchers laby.cmd and
# labyrinth.cmd, and for the runner's handling of what the launcher passes it.
# Mirrors tests\install\install.bats.
#
# Each test builds a throwaway release folder and a throwaway "system" (data
# root, Program Files folder, module folder) in TestDrive, and points the
# installer at them with its test-only options (-CodeDir, -ModuleDir, -NoPath),
# so nothing outside TestDrive is read or changed and the machine PATH is left
# alone. The release tree's core gets the test doubles of
# tests\fixtures\Doubles.ps1 appended (the administrator check, the ownership
# check and the console), as the runner tests do.
#
# The tests that complete an install lock the data root to Administrators and
# SYSTEM, so they need an elevated session, as the CI runner has; they are
# skipped without one.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeDiscovery {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.SecurityIdentifier] 'S-1-5-32-544')
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\runner\LabTestHelper.ps1')
    . (Join-Path $script:Repo 'core\safety\Release.ps1')

    # Initialize-TestRelease: a release folder with a valid release.sha256 and
    # an empty throwaway system.
    function Initialize-TestRelease {
        $base = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $r = [pscustomobject]@{
            Base    = $base
            Rel     = Join-Path $base 'release'
            Sys     = Join-Path $base 'sys'
            Root    = Join-Path $base 'sys\ProgramData\Labyrinth'
            Code    = Join-Path $base 'sys\ProgramFiles\Labyrinth'
            Modules = Join-Path $base 'sys\Modules'
        }
        New-Item -ItemType Directory -Force -Path $r.Rel, (Split-Path -Parent $r.Root),
            (Split-Path -Parent $r.Code), $r.Modules | Out-Null
        foreach ($f in 'labyrinth.ps1', 'install.ps1', 'laby.cmd', 'labyrinth.cmd') {
            Copy-Item -LiteralPath (Join-Path $script:Repo $f) -Destination $r.Rel
        }
        Copy-Item -LiteralPath (Join-Path $script:Repo 'core') -Destination $r.Rel -Recurse
        Copy-Item -LiteralPath (Join-Path $script:Repo 'config') -Destination $r.Rel -Recurse
        $doubles = [IO.File]::ReadAllText((Join-Path $script:Repo 'tests\fixtures\Doubles.ps1'))
        [IO.File]::AppendAllText((Join-Path $r.Rel 'core\Lab.ps1'), "`n$doubles")
        New-Item -ItemType Directory -Path (Join-Path $r.Rel 'manual') | Out-Null
        [IO.File]::WriteAllText((Join-Path $r.Rel 'manual\about_Labyrinth.help.txt'), "TOPIC`n    about_Labyrinth`n")
        Write-TestSeal $r
        return $r
    }

    # Write-TestSeal R: write the release list for the release folder as it is now.
    function Write-TestSeal {
        param($R)
        & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
            (Join-Path $script:Repo 'tools\release\manifest.ps1') $R.Rel | Out-Null
    }

    # Write-TestAnswer R LINES: what is typed at the "Install?" question.
    function Write-TestAnswer {
        param($R, [string[]] $Lines)
        [IO.File]::WriteAllText((Join-Path $R.Rel 'tty.in'), (($Lines | ForEach-Object { "$_`n" }) -join ''))
    }

    # Invoke-TestInstall R [-Extra ARGS] [-From SCRIPT]: run install.ps1 in its
    # own process, as an administrator would. Returns Code and Output (both
    # streams).
    function Invoke-TestInstall {
        param($R, [string[]] $Extra = @(), [string] $From = '')
        if ($From -eq '') { $From = Join-Path $R.Rel 'install.ps1' }
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $From `
                -Root $R.Root -CodeDir $R.Code -ModuleDir $R.Modules -NoPath @Extra 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        return [pscustomobject]@{
            Code   = $code
            Output = (@($out) | ForEach-Object { "$_" }) -join "`n"
        }
    }

    # Get-TestSnapshot DIR: every path under DIR, with each file's SHA-256: equal
    # before and after means unchanged.
    function Get-TestSnapshot {
        param([string] $Dir)
        $len = $Dir.TrimEnd('\').Length
        $rows = foreach ($i in @(Get-ChildItem -LiteralPath $Dir -Recurse -Force)) {
            $rel = $i.FullName.Substring($len)
            if ($i.PSIsContainer) { "D $rel" } else { "F $rel $((Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash)" }
        }
        return @($rows | Sort-Object)
    }

    # ConvertTo-TestFlat TEXT: runs of spaces squeezed, so a plan row can be
    # matched without counting its padding.
    function ConvertTo-TestFlat {
        param([string] $Text)
        return ($Text -replace ' +', ' ')
    }
}

Describe 'install.ps1 refuses, or asks, before it changes anything' {
    BeforeEach {
        $r = Initialize-TestRelease
        $before = Get-TestSnapshot $r.Sys
    }

    It 'prints the plan before the question, and answering no changes nothing' {
        Write-TestAnswer $r @('n')
        $x = Invoke-TestInstall $r
        $x.Code | Should -Be 0
        $flat = ConvertTo-TestFlat $x.Output
        $x.Output | Should -Match 'CHANGES TO THIS HOST'
        $flat | Should -Match ([regex]::Escape("Program $($r.Code) (new)"))
        $flat | Should -Match ([regex]::Escape("Data $($r.Root) (new, private)"))
        $flat | Should -Match ([regex]::Escape('Commands laby, labyrinth (new)'))
        $flat | Should -Match ([regex]::Escape('PATH not changed (-NoPath)'))
        $flat | Should -Match ([regex]::Escape('Manual Get-Help about_Labyrinth (new)'))
        $flat | Should -Match ([regex]::Escape('Config 8 templates '))
        # The release hash, in two lines of eight groups of four, before the tree.
        $sum = (Get-FileHash -LiteralPath (Join-Path $r.Rel 'release.sha256') -Algorithm SHA256).Hash.ToLowerInvariant()
        $hash = @([regex]::Matches($x.Output, '(?m)^.{3} {5}([0-9a-f]{4}(?: [0-9a-f]{4}){7}) {5}.{3}\r?$') | ForEach-Object { $_.Groups[1].Value })
        $hash.Count | Should -Be 2
        ($hash -join '').Replace(' ', '') | Should -BeExactly $sum
        $x.Output.IndexOf('WARNING') | Should -BeLessThan $x.Output.IndexOf('CHANGES TO THIS HOST')
        $x.Output | Should -Match 'Nothing was changed\.'
        [IO.File]::ReadAllText((Join-Path $r.Rel 'tty.out')) | Should -Match ([regex]::Escape('Install? [y/N]'))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'no answer at all changes nothing either' {
        [IO.File]::WriteAllText((Join-Path $r.Rel 'tty.in'), '')
        $x = Invoke-TestInstall $r
        $x.Code | Should -Be 0
        $x.Output | Should -Match 'Nothing was changed\.'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'any answer but yes is a no' {
        Write-TestAnswer $r @('maybe')
        $x = Invoke-TestInstall $r
        $x.Output | Should -Match 'Nothing was changed\.'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'without a terminal and without -y, it prints the plan and refuses' {
        New-Item -ItemType File -Path (Join-Path $r.Rel 'NO_TTY') | Out-Null
        $x = Invoke-TestInstall $r
        $x.Code | Should -Be 40
        $x.Output | Should -Match 'CHANGES TO THIS HOST'
        $x.Output | Should -Match 'no terminal to ask on'
        $x.Output | Should -Match 'add -y'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'a release that differs from release.sha256 is refused' {
        Add-Content -LiteralPath (Join-Path $r.Rel 'core\config\Config.ps1') -Value '# changed'
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match ([regex]::Escape('core/config/Config.ps1 differs from the release'))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'a file the release list does not name is refused' {
        Set-Content -LiteralPath (Join-Path $r.Rel 'core\extra.ps1') -Value 'extra' -Encoding Ascii
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match ([regex]::Escape('core/extra.ps1 is not in the release'))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'an armed revert timer is refused, naming the run and when it fires' {
        $run = '20261002T140301Z-4f2a'
        $dir = Join-Path $r.Root "state\runs\$run"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'timer') -Value 'task' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $dir 'timer-due') -Value '2026-10-02T14:08:01Z' -Encoding Ascii
        $before = Get-TestSnapshot $r.Sys
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match "run $run"
        $x.Output | Should -Match ([regex]::Escape('fires at 2026-10-02T14:08:01Z'))
        $x.Output | Should -Match ([regex]::Escape('laby -k ID'))
        $x.Output | Should -Match ([regex]::Escape('laby -u ID'))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'a folder that others can write to, above the install, is refused' {
        New-Item -ItemType File -Path (Join-Path $r.Rel 'UNTRUSTED') | Out-Null
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match 'can be changed by an account other than an administrator'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'without an Administrator it refuses' {
        New-Item -ItemType File -Path (Join-Path $r.Rel 'NOT_ADMIN') | Out-Null
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match 'must run as an Administrator'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'a code folder that is not Labyrinth''s and not empty is not replaced' {
        New-Item -ItemType Directory -Path $r.Code | Out-Null
        Set-Content -LiteralPath (Join-Path $r.Code 'notes.txt') -Value 'someone else' -Encoding Ascii
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 20
        $x.Output | Should -Match 'is not a Labyrinth folder|is not empty and is not a Labyrinth folder'
        (Get-Content -LiteralPath (Join-Path $r.Code 'notes.txt')) | Should -Be 'someone else'
    }

    It 'another command named labyrinth on the PATH is refused, and nothing is installed' {
        $other = Join-Path $r.Base 'other'
        New-Item -ItemType Directory -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'labyrinth.cmd') -Value '@echo off' -Encoding Ascii
        $savedPath = $env:PATH
        $env:PATH = "$other;$savedPath"
        try {
            $x = Invoke-TestInstall $r @('-Yes')
        } finally {
            $env:PATH = $savedPath
        }
        $x.Code | Should -Be 20
        $x.Output | Should -Match ([regex]::Escape("the command name labyrinth is taken: a command named labyrinth is already at $other\labyrinth.cmd"))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'another command named laby on the PATH is named in the plan, and the command to type is labyrinth' {
        $other = Join-Path $r.Base 'other'
        New-Item -ItemType Directory -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'laby.cmd') -Value '@echo off' -Encoding Ascii
        Write-TestAnswer $r @('n')
        $savedPath = $env:PATH
        $env:PATH = "$other;$savedPath"
        try {
            $x = Invoke-TestInstall $r
        } finally {
            $env:PATH = $savedPath
        }
        $x.Code | Should -Be 0
        (ConvertTo-TestFlat $x.Output) | Should -Match ([regex]::Escape("laby is taken by $other\laby.cmd: type labyrinth instead"))
        (ConvertTo-TestFlat $x.Output) | Should -Match ([regex]::Escape('Commands labyrinth (new; laby is taken)'))
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'usage errors exit 40 and name the fix; -Help prints the usage' {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $r.Rel 'install.ps1') -Root 'relative\dir' 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        $code | Should -Be 40
        ((@($out) | ForEach-Object { "$_" }) -join "`n") | Should -Match 'the folder must be a full path'
        $out = & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $r.Rel 'install.ps1') -Help
        $LASTEXITCODE | Should -Be 0
        ((@($out) | ForEach-Object { "$_" }) -join "`n") | Should -Match 'Usage: \.\\install\.ps1'
    }
}

Describe 'install.ps1 installs' -Skip:(-not $elevated) {
    BeforeEach {
        $r = Initialize-TestRelease
    }

    It 'yes installs the code, the data root, the commands, the help topic and the templates' {
        Write-TestAnswer $r @('y')
        $x = Invoke-TestInstall $r
        $x.Code | Should -Be 0
        $x.Output | Should -Match 'Installed\.'
        $x.Output | Should -Match ([regex]::Escape('Next: laby -Root'))
        # The code, with its commands, checked against its own release list as the runner will.
        foreach ($f in 'labyrinth.ps1', 'install.ps1', 'laby.cmd', 'labyrinth.cmd', 'release.sha256', 'config\hosts.example', 'manual\about_Labyrinth.help.txt') {
            Join-Path $r.Code $f | Should -Exist
        }
        (Test-LabRelease -Root $r.Code).Status | Should -Be 'ok'
        # The data root: only Administrators and SYSTEM, nothing inherited.
        $acl = Get-Acl -LiteralPath $r.Root
        $acl.AreAccessRulesProtected | Should -BeTrue
        $ids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $ids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        foreach ($d in 'etc', 'state', 'logs', 'backup') { Join-Path $r.Root $d | Should -Exist }
        # The templates, without the .example ending.
        Join-Path $r.Root 'etc\hosts' | Should -Exist
        Join-Path $r.Root 'etc\protected-accounts' | Should -Exist
        Join-Path $r.Root 'etc\hosts.example' | Should -Not -Exist
        (Get-FileHash -LiteralPath (Join-Path $r.Root 'etc\hosts')).Hash |
            Should -Be (Get-FileHash -LiteralPath (Join-Path $r.Rel 'config\hosts.example')).Hash
        # The help topic: a module folder with a manifest and the topic in en-US.
        Join-Path $r.Modules 'Labyrinth\Labyrinth.psd1' | Should -Exist
        Join-Path $r.Modules 'Labyrinth\en-US\about_Labyrinth.help.txt' | Should -Exist
        { Import-PowerShellDataFile -LiteralPath (Join-Path $r.Modules 'Labyrinth\Labyrinth.psd1') } | Should -Not -Throw
    }

    It '-y answers the question for the installer' {
        New-Item -ItemType File -Path (Join-Path $r.Rel 'NO_TTY') | Out-Null
        $x = Invoke-TestInstall $r @('-y')
        $x.Code | Should -Be 0
        Join-Path $r.Code 'labyrinth.ps1' | Should -Exist
    }

    It 'a second run changes nothing' {
        (Invoke-TestInstall $r @('-Yes')).Code | Should -Be 0
        $before = Get-TestSnapshot $r.Sys
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        $x.Output | Should -Match 'Nothing to change\.'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'configuration files that are already there are kept' {
        New-Item -ItemType Directory -Path (Join-Path $r.Root 'etc') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $r.Root 'etc\hosts'), "my own hosts`n")
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $r.Root 'etc\hosts')) | Should -Be "my own hosts`n"
        Join-Path $r.Root 'etc\protected-accounts' | Should -Exist
        $x.Output | Should -Match ([regex]::Escape('copied, 1 kept'))
    }

    It 'an existing data root that is open to other accounts is made private, its files untouched' {
        New-Item -ItemType Directory -Path (Join-Path $r.Root 'logs') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $r.Root 'logs\run.txt'), "log`n")
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        $x.Output | Should -Match ([regex]::Escape('(kept, made private)'))
        (Get-Acl -LiteralPath $r.Root).AreAccessRulesProtected | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $r.Root 'logs\run.txt')) | Should -Be "log`n"
    }

    It 'a reinstall replaces the code completely and never touches state or configuration' {
        (Invoke-TestInstall $r @('-Yes')).Code | Should -Be 0
        [IO.File]::WriteAllText((Join-Path $r.Root 'etc\hosts'), "mine`n")
        $run = Join-Path $r.Root 'state\runs\20261002T140301Z-4f2a'
        New-Item -ItemType Directory -Path $run | Out-Null
        [IO.File]::WriteAllText((Join-Path $run 'manifest.jsonl'), "record`n")
        [IO.File]::WriteAllText((Join-Path $r.Root 'logs\run.txt'), "log`n")
        # A stray file in the installed code would fail the runner's release check.
        [IO.File]::WriteAllText((Join-Path $r.Code 'core\stray.ps1'), "planted`n")
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        Join-Path $r.Code 'core\stray.ps1' | Should -Not -Exist
        (Test-LabRelease -Root $r.Code).Status | Should -Be 'ok'
        [IO.File]::ReadAllText((Join-Path $r.Root 'etc\hosts')) | Should -Be "mine`n"
        [IO.File]::ReadAllText((Join-Path $run 'manifest.jsonl')) | Should -Be "record`n"
        [IO.File]::ReadAllText((Join-Path $r.Root 'logs\run.txt')) | Should -Be "log`n"
        # Nothing is left beside the code folder.
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $r.Code) -Force | ForEach-Object { $_.Name }) | Should -Be @('Labyrinth')
    }

    It 'a data root the runner has used, with its own administrator account added, still counts as private' {
        (Invoke-TestInstall $r @('-Yes')).Code | Should -Be 0
        # What Protect-LabDataRoot adds on the first run: the account that runs Labyrinth.
        $acl = Get-Acl -LiteralPath $r.Root
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl',
                    'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $r.Root -AclObject $acl
        $before = Get-TestSnapshot $r.Sys
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        $x.Output | Should -Match 'Nothing to change\.'
        Get-TestSnapshot $r.Sys | Should -Be $before
    }

    It 'a run with no timer armed does not stop the install' {
        $run = Join-Path $r.Root 'state\runs\20261002T140301Z-4f2a'
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $run 'manifest.jsonl'), "record`n")
        (Invoke-TestInstall $r @('-Yes')).Code | Should -Be 0
    }

    It 'a copy with no release list installs with a note that it was not checked' {
        Remove-Item -LiteralPath (Join-Path $r.Rel 'release.sha256')
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        (ConvertTo-TestFlat $x.Output) | Should -Match ([regex]::Escape(' This copy has no release.sha256, '))
        (ConvertTo-TestFlat $x.Output) | Should -Match ([regex]::Escape(' so nothing proves that it is genuine. '))
        Join-Path $r.Code 'labyrinth.ps1' | Should -Exist
        Join-Path $r.Code 'release.sha256' | Should -Not -Exist
    }

    It 'a copy with no built manual skips the help topic in one line and still installs' {
        Remove-Item -LiteralPath (Join-Path $r.Rel 'manual') -Recurse -Force
        Write-TestSeal $r
        $x = Invoke-TestInstall $r @('-Yes')
        $x.Code | Should -Be 0
        (ConvertTo-TestFlat $x.Output) | Should -Match ([regex]::Escape('Manual skipped: this copy has no built manual'))
        Join-Path $r.Code 'labyrinth.ps1' | Should -Exist
        Join-Path $r.Modules 'Labyrinth' | Should -Not -Exist
    }

    It 'the installed copy refuses to install over itself' {
        (Invoke-TestInstall $r @('-Yes')).Code | Should -Be 0
        $x = Invoke-TestInstall $r @('-Yes') -From (Join-Path $r.Code 'install.ps1')
        $x.Code | Should -Be 20
        $x.Output | Should -Match 'installed copy'
    }
}

Describe 'the launchers laby.cmd and labyrinth.cmd' {
    BeforeEach {
        $t = Initialize-TestLab
        Copy-Item -LiteralPath (Join-Path $script:Repo 'laby.cmd') -Destination $t.Lab
        Copy-Item -LiteralPath (Join-Path $script:Repo 'labyrinth.cmd') -Destination $t.Lab
    }

    It 'run labyrinth.ps1 beside them with a bypass for this one process, and pass the exit code back' {
        foreach ($n in 'laby', 'labyrinth') {
            $text = [IO.File]::ReadAllText((Join-Path $script:Repo "$n.cmd"))
            $text | Should -Match 'setlocal'
            $text | Should -Match ('(?m)^set "LAB_SELF={0}"' -f $n)
            $text | Should -Match '-NoProfile -ExecutionPolicy Bypass -File "%~dp0labyrinth\.ps1" %\*'
            $text | Should -Match 'exit /b %ERRORLEVEL%'
            # CRLF line ends, so cmd.exe reads labels and lines the way it expects.
            $text | Should -Match "`r`n"
        }
    }

    It 'started through the launcher, the runner names itself laby or labyrinth, and the exit code comes back' {
        Push-Location -LiteralPath $t.Lab
        try {
            $out = & cmd.exe /c laby.cmd -h
            $LASTEXITCODE | Should -Be 0
            @($out)[0] | Should -Match '^Usage: laby PHASE'
            $out = & cmd.exe /c labyrinth.cmd -h
            @($out)[0] | Should -Match '^Usage: labyrinth PHASE'
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = & cmd.exe /c laby.cmd -Nonsense 2>&1
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $saved
            }
            $code | Should -Be 40
            (@($out) | ForEach-Object { "$_" }) -join "`n" | Should -Match "laby: unknown option"
        } finally {
            Pop-Location
        }
    }

    It 'a comma list typed after -Approve reaches the runner whole, even though PowerShell passes it in pieces' {
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.ask'
        Push-Location -LiteralPath $t.Lab
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # The second entry is malformed, so the runner names it: it got there as part of the list.
            $out = & cmd.exe /c laby.cmd -r observe -Root $t.Root -Config $t.Etc -Approve observe.ask:item-a@2a2c17aaaf66,observe.ask:item-b@BBBB 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
            Pop-Location
        }
        $code | Should -Be 40
        (@($out) | ForEach-Object { "$_" }) -join "`n" | Should -Match ([regex]::Escape("-Approve: not <module-id>:<item-id>@<fingerprint>: 'observe.ask:item-b@BBBB'"))
    }
}

Describe 'labyrinth.ps1 joins the words that follow -Approve' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.ask'
        $a = '2a2c17aaaf66'   # the fixture's fingerprint of item-a
    }

    It 'words that look like list items are one list; the phase after them stays a phase' {
        $x = Invoke-TestLab $t @('-r', '-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1', '-Root', $t.Root, '-Config', $t.Etc,
            '-Approve', "observe.ask:item-a@$a", "observe.ask:item-z@$a", 'observe') -Answers @('no')
        $x.Code | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $t.Lab 'APPROVED_ITEMS')) | Should -Be @('item-a')
        @($x.Output -split "`r?`n") -ccontains "Not in this run's plan, so ignored: observe.ask:item-z@$a" | Should -BeTrue
    }

    It 'the words give the same result as the one comma list' {
        $x = Invoke-TestLab $t @('-r', 'observe', '-BreakGlass', 'labadmin', '-ConfirmGroup', 'ring1', '-Root', $t.Root, '-Config', $t.Etc,
            '-Approve', "observe.ask:item-a@$a", "observe.ask:item-b@000000000000", "observe.ask:item-z@$a") -Answers @('no')
        $x.Code | Should -Be 0
        @(Get-Content -LiteralPath (Join-Path $t.Lab 'APPROVED_ITEMS')) | Should -Be @('item-a')
        $lines = @($x.Output -split "`r?`n")
        ($lines -ccontains "Not in this run's plan, so ignored: observe.ask:item-z@$a") | Should -BeTrue
        ($lines -ccontains '  Found:     item-b changed since the plan, so it is left alone') | Should -BeTrue
    }

    It 'a word that is not a list item is not taken into the list' {
        $x = Invoke-TestLabCapture $t @('-r', '-Root', $t.Root, '-Config', $t.Etc, '-Approve', "observe.ask:item-a@$a", 'observe')
        $x.Err | Should -Not -Match 'Approve: not'
    }

    It 'a malformed entry among the words is named, as it would be in a comma list' {
        $x = Invoke-TestLabCapture $t @('-r', 'observe', '-Root', $t.Root, '-Config', $t.Etc, '-Approve', "observe.ask:item-a@$a", 'observe.ask:item-b@BBBB')
        $x.Code | Should -Be 40
        $x.Err | Should -Match ([regex]::Escape("-Approve: not <module-id>:<item-id>@<fingerprint>: 'observe.ask:item-b@BBBB'"))
    }
}

Describe 'labyrinth.ps1 started through the launcher' {
    BeforeEach {
        $t = Initialize-TestLab
        $saved = $env:LAB_SELF
    }

    AfterEach {
        if ($null -eq $saved) { Remove-Item Env:\LAB_SELF -ErrorAction SilentlyContinue } else { $env:LAB_SELF = $saved }
    }

    It 'shows the name the launcher set, laby or labyrinth' {
        $env:LAB_SELF = 'laby'
        (Invoke-TestLabCapture $t @('-h')).Out | Should -Match '^Usage: laby PHASE'
        $env:LAB_SELF = 'labyrinth'
        (Invoke-TestLabCapture $t @('-h')).Out | Should -Match '^Usage: labyrinth PHASE'
    }

    It 'a usage error starts with that name and points to its help' {
        $env:LAB_SELF = 'laby'
        $x = Invoke-TestLabCapture $t @('-Nonsense')
        $x.Code | Should -Be 40
        @($x.Err -split "`r?`n")[0] | Should -Match "^laby: unknown option"
        $x.Err | Should -Match ([regex]::Escape("Try 'laby -h'."))
    }

    It 'any other value of LAB_SELF is ignored' {
        $env:LAB_SELF = 'something-else'
        (Invoke-TestLabCapture $t @('-h')).Out | Should -Not -Match '^Usage: something-else'
    }
}

Describe 'the installer screen (core\banner\Banner.ps1)' {
    BeforeAll {
        . (Join-Path $script:Repo 'core\banner\Banner.ps1')
        $sha = '3f9a1c2b8e4d0a775b19c3e29d046f8a2b6e71c0d95a4e3f08b2a6c15e97c21e'
        $box = @{}
        foreach ($k in @($LabBox.Keys)) { $box[$k] = $LabBox[$k] }
    }

    It 'with box lines: the maze, the version, what it is, the notice, then the warning box with the hash' {
        $s = @(Get-LabBanner -Unicode $true -Version '0.1.0' -Sha $sha)
        $maze = @(Get-LabBannerMaze -Unicode $true)
        $maze.Count | Should -Be 7
        for ($i = 0; $i -lt 7; $i++) { $s[$i] | Should -BeExactly $maze[$i] }
        $s[7] | Should -BeExactly 'VERSION 0.1.0 (https://dotnetdork.github.io/Labyrinth/)'
        $s[8] | Should -BeExactly ''
        $s[9] | Should -BeExactly ' Rapid first-minute hardening tool for Linux & Windows,'
        $s[10] | Should -BeExactly ' with traps that log every attacker move as a tripwire.'
        $s[11] | Should -BeExactly ''
        $s[12] | Should -BeExactly '      Copyright (c) 2026 Jay Sausa. See LICENSE.'
        $s[13] | Should -BeExactly ''
        for ($i = 14; $i -lt 23; $i++) { $s[$i].Length | Should -Be 55 }
        $v = $box.V
        $s[14] | Should -BeExactly ($box.TL + ($box.H * 53) + $box.TR)
        $s[15] | Should -BeExactly ($v + (' ' * 23) + 'WARNING' + (' ' * 23) + $v)
        $s[16] | Should -BeExactly ($box.ML + ($box.H * 53) + $box.MR)
        $s[17] | Should -BeExactly ($v + (' ' * 9) + "If this SHA-256 doesn't match your" + (' ' * 10) + $v)
        $s[18] | Should -BeExactly ($v + (' ' * 8) + 'offline record, it was tampered with.' + (' ' * 8) + $v)
        $s[19] | Should -BeExactly ($v + (' ' * 53) + $v)
        $s[20] | Should -BeExactly ($v + '       3f9a 1c2b 8e4d 0a77 5b19 c3e2 9d04 6f8a       ' + $v)
        $s[21] | Should -BeExactly ($v + '       2b6e 71c0 d95a 4e3f 08b2 a6c1 5e97 c21e       ' + $v)
        $s[22] | Should -BeExactly ($box.BL + ($box.H * 53) + $box.BR)
        $s.Count | Should -Be 23
        foreach ($l in $s) { $l.Length | Should -BeLessOrEqual 79 }
    }

    It 'in plain ASCII: the same shape, with + - and |' {
        $s = @(Get-LabBanner -Unicode $false -Version '0.1.0' -Sha $sha)
        $u = @(Get-LabBanner -Unicode $true -Version '0.1.0' -Sha $sha)
        $s.Count | Should -Be $u.Count
        for ($i = 0; $i -lt $s.Count; $i++) {
            $s[$i].Length | Should -Be $u[$i].Length
            $s[$i] | Should -Not -Match '[^ -~]'
        }
        $s[0] | Should -BeLike '+ IN -*'
        $s[6] | Should -BeLike '*+ OUT +'
        $s[14] | Should -BeExactly ('+' + ('-' * 53) + '+')
        $s[15] | Should -BeExactly ('|' + (' ' * 23) + 'WARNING' + (' ' * 23) + '|')
        $s[16] | Should -BeExactly ('+' + ('-' * 53) + '+')
        $s[20] | Should -BeExactly '|       3f9a 1c2b 8e4d 0a77 5b19 c3e2 9d04 6f8a       |'
    }

    It 'with no release list, the box says nothing proves the copy is genuine' {
        $s = @(Get-LabBanner -Unicode $false -Version '0.1.0' -Sha '')
        $s[17] | Should -BeExactly ('|' + (' ' * 10) + 'This copy has no release.sha256,' + (' ' * 11) + '|')
        $s[18] | Should -BeExactly ('|' + (' ' * 8) + 'so nothing proves that it is genuine.' + (' ' * 8) + '|')
        $s[19] | Should -BeExactly ('+' + ('-' * 53) + '+')
        ($s -join "`n") | Should -Not -Match '[0-9a-f]{4} [0-9a-f]{4}'
    }

    It 'the tree of changes: box branches and an arrow, or plain ASCII' {
        $rows = @(@('Program', 'C:\P (new)'), @('Config', '3 templates -> C:\D\etc'))
        $t = @(Get-LabBannerTree -Unicode $true -Arrow $true -Rows $rows)
        $t[0] | Should -BeExactly '  CHANGES TO THIS HOST'
        $t[1] | Should -BeExactly ('   ' + $box.Mid + $box.IH + $box.IH + ' Program   C:\P (new)')
        $t[2] | Should -BeExactly ('   ' + $box.Last + $box.IH + $box.IH + ' Config    3 templates ' + $box.Arrow + ' C:\D\etc')
        $a = @(Get-LabBannerTree -Unicode $false -Arrow $false -Rows $rows)
        $a[1] | Should -BeExactly '   |-- Program   C:\P (new)'
        $a[2] | Should -BeExactly '   `-- Config    3 templates -> C:\D\etc'
    }

    It 'box lines are used only when the console can write them' {
        $saved = [Console]::OutputEncoding
        try {
            try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {
                Set-ItResult -Skipped -Because 'this session has no console whose encoding can be set'
                return
            }
            Test-LabBannerUnicode | Should -BeTrue
            [Console]::OutputEncoding = [Text.Encoding]::ASCII
            Test-LabBannerUnicode | Should -BeFalse
        } finally {
            try { [Console]::OutputEncoding = $saved } catch { $null = $_ }
        }
    }
}
