#Requires -Version 5.1
# The host checks of labyrinth.ps1 (docs\Conventions.md section 3.1): plan,
# apply and probe refuse a host listed for another platform or as an
# appliance; keep and rollback skip the checks, so a stored revert-timer
# command still works after the configuration changes. Mirrors
# hostcheck.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Write-TestPlatform T PLATFORM: list this host, in group ring1, for PLATFORM.
    function Write-TestPlatform {
        param($T, [string] $Platform)
        Write-TestConfig $T 'hosts' @("$((($env:COMPUTERNAME -split '\.')[0])) ring1 test $Platform")
    }

    # Invoke-TestLabRun T ARGS: labyrinth.ps1 with the test data root.
    function Invoke-TestLabRun {
        param($T, [string[]] $Arguments)
        Invoke-TestLab $T (@($Arguments) + @('-Root', $T.Root, '-Config', $T.Etc))
    }
}

Describe 'labyrinth.ps1 host checks' {
    BeforeEach {
        $t = Initialize-TestLab
        $toggle = Join-Path $t.Lab 'toggle.conf'
        Write-TestProfile $t 'observe.toggle'
        Write-TestConfig $t 'services' @('web http web.test 80 -')
        $commands = @(@('plan', 'observe'), @('apply', 'observe'), @('probe'))
    }

    It 'plan, apply and probe refuse a host listed for Linux' {
        Write-TestPlatform $t 'ubuntu'
        foreach ($words in $commands) {
            $r = Invoke-TestLabRun $t $words
            $r.Code | Should -Be 20
            $r.Output | Should -Match ([regex]::Escape("does not serve this host's platform, ubuntu"))
        }
        $t.Root | Should -Not -Exist
        $toggle | Should -Not -Exist
    }

    It 'plan, apply and probe never act on an appliance' {
        Write-TestPlatform $t 'appliance'
        foreach ($words in $commands) {
            $r = Invoke-TestLabRun $t $words
            $r.Code | Should -Be 20
            $r.Output | Should -Match 'is an appliance.*never changes it'
            $r.Output | Should -Match 'Configure it by hand, from its runbook'
        }
        $t.Root | Should -Not -Exist
    }

    It 'windows is served, and an unlisted host may still plan' {
        Write-TestPlatform $t 'windows'
        (Invoke-TestLabRun $t @('plan', 'observe')).Code | Should -Be 10
        Remove-Item -LiteralPath (Join-Path $t.Etc 'hosts')
        (Invoke-TestLabRun $t @('plan', 'observe', '-Profile', 'test')).Code | Should -Be 10
    }

    It 'keep still works after this host''s line changes platform' {
        Write-TestPlatform $t 'windows'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        Write-TestPlatform $t 'ubuntu'
        $k = Invoke-TestRunCommand $t 'keep' $id
        $k.Code | Should -Be 0
        $k.Output | Should -Match "kept: the revert timer for run $id is cancelled"
    }

    It 'the stored rollback still works after the -Config folder is gone' {
        Write-TestPlatform $t 'windows'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        Remove-Item -LiteralPath $t.Etc -Recurse -Force
        (Invoke-TestRunCommand $t 'rollback' $id).Code | Should -Be 0
        $toggle | Should -Not -Exist
    }
}
