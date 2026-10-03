#Requires -Version 5.1
# Pester 5 tests for how labyrinth.ps1 reports failures that used to be
# hidden (docs\Conventions.md section 4): the last catch, and the manifest
# writes that are checked by hand. Mirrors failures.bats. Failures are
# injected by appending a stand-in to the throwaway core.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Add-TestStandIn T TEXT: append a function to the throwaway core.
    function Add-TestStandIn {
        param($T, [string] $Text)
        Add-Content -LiteralPath (Join-Path $T.Lab 'core\Lab.ps1') -Value $Text
    }

    # The timer is cancelled, then the manifest can no longer be written.
    $readOnlyAfterCancel = @'
function Unregister-LabRevertTimer {
    param([string] $RunId)
    $d = Get-LabRunDir $RunId
    Remove-Item -LiteralPath (Join-Path $d 'timer'), (Join-Path $d 'timer-due') -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath (Join-Path $d 'manifest.jsonl') -Name IsReadOnly -Value $true
}
'@

    # Clear-TestReadOnly T RUN: let TestDrive remove the manifest again.
    function Clear-TestReadOnly {
        param($T, [string] $RunId)
        Set-ItemProperty -LiteralPath (Join-Path $T.Root "state\runs\$RunId\manifest.jsonl") -Name IsReadOnly -Value $false
    }
}

Describe 'labyrinth.ps1 hidden failures' {
    BeforeEach {
        $t = Initialize-TestLab
        $toggle = Join-Path $t.Lab 'toggle.conf'
        Write-TestHost $t 'ring1'
        Write-TestProfile $t 'observe.toggle'
    }

    It 'an internal error after a change says the run stopped and keeps the timer' {
        Add-TestStandIn $t 'function Exit-LabLock { throw ''the lock is gone'' }'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 40
        $id = Get-TestRunId $r.Output
        $r.Output | Should -Match 'labyrinth: internal error at line \d+: the lock is gone'
        $r.Output | Should -Match 'The run stopped\. Earlier changes stay until the revert timer undoes them\.'
        $r.Output | Should -Match 'The revert timer rolls this run back at \d\d:\d\d UTC'
        $r.Output | Should -Match ([regex]::Escape("To undo them now: labyrinth.ps1 rollback $($id.Substring($id.Length - 4))"))
        Join-Path $t.Root "state\runs\$id\timer" | Should -Exist
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
    }

    It 'an internal error before any change says nothing was changed' {
        # The core is loaded after the runner's functions, so this replaces one.
        Add-TestStandIn $t 'function Assert-LabProtectedSet { throw ''no protected set'' }'
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'internal error at line \d+: no protected set'
        $r.Output | Should -Match 'Nothing was changed\.'
        $r.Output | Should -Not -Match 'At line:'
        $toggle | Should -Not -Exist
        Join-Path $t.Root 'state\runs' | Should -Not -Exist
    }

    It 'a module is not applied when the run manifest cannot be written' {
        # Arming the timer comes just before apply_start is recorded: make
        # the manifest read-only there.
        Add-TestStandIn $t @'
function Register-LabRevertTimer {
    param($Seconds, $RunId, $Execute, $Argument)
    Set-ItemProperty -LiteralPath (Join-Path (Get-LabRunDir $RunId) 'manifest.jsonl') -Name IsReadOnly -Value $true
}
'@
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        Clear-TestReadOnly $t (Get-TestRunId $r.Output)
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'the run manifest cannot be written, so it is not applied'
        $r.Output | Should -Not -Match 'internal error'
        $toggle | Should -Not -Exist
    }

    It 'the expected failures are not reported as internal errors' {
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_VERIFY') | Out-Null
        $r = Invoke-TestApply $t @('labadmin', 'ring1', 'keep')
        $r.Code | Should -Be 30
        $r.Output | Should -Not -Match 'internal error'
        Remove-Item -LiteralPath (Join-Path $t.Lab 'FAIL_VERIFY')
        New-Item -ItemType File -Path (Join-Path $t.Lab 'FAIL_APPLY') | Out-Null
        # Break-glass is asked only on the first apply.
        $r = Invoke-TestApply $t @('ring1', 'keep')
        $r.Code | Should -Be 40
        $r.Output | Should -Not -Match 'internal error'
        Remove-Item -LiteralPath (Join-Path $t.Lab 'FAIL_APPLY')
        $r = Invoke-TestPlan $t
        $r.Code | Should -Be 10
        $r.Output | Should -Not -Match 'internal error'
        $r = Invoke-TestApply $t @('ring1', 'no')
        $r.Code | Should -Be 0
        $id = Get-TestRunId $r.Output
        $r = Invoke-TestRunCommand $t 'rollback' $id
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'internal error'
        $r = Invoke-TestRunCommand $t 'keep' $id
        $r.Code | Should -Be 20
        $r.Output | Should -Not -Match 'internal error'
        Write-TestHost $t 'manual'
        $r = Invoke-TestApply $t @()
        $r.Code | Should -Be 20
        $r.Output | Should -Not -Match 'internal error'
    }

    It 'keep that cannot cancel the timer says when it fires and how to retry' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        Add-TestStandIn $t 'function Unregister-LabRevertTimer { throw ''refused'' }'
        $k = Invoke-TestRunCommand $t 'keep' $id
        $k.Code | Should -Be 40
        $k.Output | Should -Match 'will still roll it back at \d\d:\d\d UTC'
        $k.Output | Should -Match ([regex]::Escape("Retry: labyrinth.ps1 keep $($id.Substring($id.Length - 4))"))
    }

    It 'keep that cancels the timer but cannot record it says so and exits 40' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        Add-TestStandIn $t $readOnlyAfterCancel
        $k = Invoke-TestRunCommand $t 'keep' $id
        Clear-TestReadOnly $t $id
        $k.Code | Should -Be 40
        $k.Output | Should -Match 'is cancelled, so the changes stay, but the keep could not be recorded'
        $k.Output | Should -Not -Match 'kept: the revert timer'
        $k.Output | Should -Not -Match 'internal error'
    }

    It 'a rollback that cannot be recorded still rolls back and exits 40' {
        $id = Get-TestRunId (Invoke-TestApply $t @('labadmin', 'ring1', 'no')).Output
        Add-TestStandIn $t $readOnlyAfterCancel
        $r = Invoke-TestRunCommand $t 'rollback' $id
        Clear-TestReadOnly $t $id
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'is rolled back, but the manifest cannot be written to record it'
        $toggle | Should -Not -Exist
    }
}
