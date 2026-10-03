#Requires -Version 5.1
# Errors that stop labyrinth.ps1 say what failed, then how to recover, on
# one prefixed line and one fix line (docs\Conventions.md section 3.2).
# Mirrors hints.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Invoke-TestHint T ARGS: labyrinth.ps1 with the test data root; the
    # result's Lines are its standard error, one line each.
    function Invoke-TestHint {
        param($T, [string[]] $Arguments)
        $r = Invoke-TestLabCapture $T (@($Arguments) + @('-Root', $T.Root, '-Config', $T.Etc))
        $r | Add-Member -NotePropertyName Lines -NotePropertyValue @($r.Err.TrimEnd() -split "`r?`n")
        return $r
    }
}

Describe 'labyrinth.ps1 recovery hints' {
    BeforeEach {
        $t = Initialize-TestLab
        Write-TestProfile $t 'observe.clean'
    }

    It 'a command that needs an Administrator says how to get one' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'NOT_ADMIN') | Out-Null
        foreach ($words in @(@('runs'), @('keep', '4f2a'), @('rollback', '4f2a'), @('apply', 'observe'))) {
            $r = Invoke-TestHint $t $words
            $r.Code | Should -Be 20
            $r.Lines[0] | Should -Match 'needs an elevated Administrator session'
            $r.Lines[1] | Should -Be "Run it again in PowerShell opened with 'Run as administrator'."
        }
    }

    It 'a -Config that is missing, or is a file, says which, and what to give' {
        $missing = Join-Path $t.Etc 'missing'
        $r = Invoke-TestLabCapture $t @('plan', 'observe', '-Profile', 'test', '-Root', $t.Root, '-Config', $missing)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("labyrinth: the -Config folder does not exist: $missing"))
        $r.Err | Should -Match ([regex]::Escape('leave out -Config to use <root>\etc'))
        $file = Join-Path $t.Etc 'protected-accounts'
        $r = Invoke-TestLabCapture $t @('plan', 'observe', '-Profile', 'test', '-Root', $t.Root, '-Config', $file)
        $r.Code | Should -Be 40
        $r.Err | Should -Match ([regex]::Escape("labyrinth: the -Config path is a file, not a folder: $file"))
    }

    It 'an unknown profile lists the profiles there are' {
        $r = Invoke-TestHint $t @('plan', 'observe', '-Profile', 'nosuch')
        $r.Code | Should -Be 40
        $r.Lines[0] | Should -Be 'labyrinth: no profile named nosuch'
        $r.Lines[1] | Should -Match '^Profiles here: .*test'
    }

    It 'a malformed hosts file is one prefixed line with the file and line' {
        Write-TestConfig $t 'hosts' @('garbage')
        $r = Invoke-TestHint $t @('plan', 'observe', '-Profile', 'test')
        $r.Code | Should -Be 40
        $r.Lines[0] | Should -Be "labyrinth: the hosts file is malformed: $(Join-Path $t.Etc 'hosts'):1: expected: host group profile platform"
        $r.Lines[1] | Should -Match '^Each line is: host group profile platform\.'
    }

    It 'a missing or empty protected set says which, and what to put in it' {
        $file = Join-Path $t.Etc 'protected-accounts'
        Remove-Item -LiteralPath $file
        $r = Invoke-TestHint $t @('plan', 'observe', '-Profile', 'test')
        $r.Code | Should -Be 20
        $r.Lines[0] | Should -Be "labyrinth: the protected set is not loaded, so nothing runs: there is no $file"
        $r.Lines[1] | Should -Match '^List, one "account class" per line, the accounts'
        Write-TestConfig $t 'protected-accounts' @()
        $r = Invoke-TestHint $t @('plan', 'observe', '-Profile', 'test')
        $r.Code | Should -Be 20
        $r.Lines[0] | Should -Match ([regex]::Escape("$file lists no accounts") + '$')
    }

    It 'a bad event.conf or service list names the line' {
        Write-TestConfig $t 'event.conf' @('bad line')
        $r = Invoke-TestHint $t @('plan', 'observe', '-Profile', 'test')
        $r.Code | Should -Be 40
        $r.Lines[0] | Should -Be "labyrinth: event.conf is malformed: $(Join-Path $t.Etc 'event.conf'):1: expected KEY=value"
        $r.Lines[1] | Should -Be 'Correct that line, then run the same command again.'
        Remove-Item -LiteralPath (Join-Path $t.Etc 'event.conf')
        $r = Invoke-TestHint $t @('probe')
        $r.Code | Should -Be 20
        $r.Lines[0] | Should -Be "labyrinth: no service list at $(Join-Path $t.Etc 'services')"
        $r.Lines[1] | Should -Match '^List the scored services there'
        Write-TestConfig $t 'services' @('web')
        $r = Invoke-TestHint $t @('probe')
        $r.Code | Should -Be 40
        $r.Lines[0] | Should -Match ('^' + [regex]::Escape("labyrinth: the service list is malformed: $(Join-Path $t.Etc 'services'):1: "))
        $r.Lines.Count | Should -Be 2
    }

    It 'a host listed for another platform says where to run' {
        Write-TestConfig $t 'hosts' @("$script:ThisHost ring1 test ubuntu")
        $r = Invoke-TestHint $t @('plan', 'observe')
        $r.Code | Should -Be 20
        $r.Lines[0] | Should -Be "labyrinth: this runner does not serve this host's platform, ubuntu"
        $r.Lines[1] | Should -Be "Use the runner for ubuntu, or correct this host's line in $(Join-Path $t.Etc 'hosts')"
    }
}
