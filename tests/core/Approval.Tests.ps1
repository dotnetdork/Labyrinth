#Requires -Version 5.1
# Pester 5 unit tests for the approval helpers (core\approval\Approval.ps1,
# docs/Conventions.md section 3.1, "Approval items").

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
}

Describe 'approval items' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LAB_CONFIG_DIR = Join-Path $root 'etc'
        $env:LAB_STATE_DIR = Join-Path $root 'state'
        $env:LAB_BACKUP_DIR = Join-Path $root 'backup'
        $env:LAB_LOG_DIR = Join-Path $root 'logs'
        $env:LAB_RUN_ID = '20261005T120000Z-abcd'
        $env:LAB_MODULE_ID = 'lockout.persistence'
        $env:LAB_DRY_RUN = '0'
        $env:LAB_APPROVED = ''
    }

    It 'fingerprint: the first 12 hex digits of the SHA-256 of the state, as on Linux' {
        Get-LabItemFingerprint -Text 'item-a' | Should -BeExactly '2a2c17aaaf66'
        Get-LabItemFingerprint -Text '' | Should -BeExactly 'e3b0c44298fc'
    }

    It 'item: one tab-separated line; a malformed field is refused' {
        Write-LabItem -Id 'task-1' -Category 'task' -Fingerprint '2a2c17aaaf66' -Reason "runs`tfrom a temporary folder" |
            Should -BeExactly "item`ttask-1`ttask`t2a2c17aaaf66`truns from a temporary folder"
        { Write-LabItem -Id 'Task-1' -Category 'task' -Fingerprint '2a2c17aaaf66' } | Should -Throw '*malformed item*'
        { Write-LabItem -Id 'task-1' -Category 'task' -Fingerprint '2A2C17AAAF66' } | Should -Throw '*malformed item*'
        { Write-LabItem -Id 'task-1' -Category 'task' -Fingerprint '2a2c17' } | Should -Throw '*malformed item*'
    }

    It 'approved: only an item a person approved, at the fingerprint of the plan' {
        $env:LAB_APPROVED = 'task-1@2a2c17aaaf66 svc-2@f09f429ea5f1'
        Test-LabApproved -Id 'task-1' -Fingerprint '2a2c17aaaf66' | Should -Be 0
        Test-LabApproved -Id 'task-3' -Fingerprint '2a2c17aaaf66' | Should -Be 1
        Test-LabApproved -Id 'task' -Fingerprint '2a2c17aaaf66' | Should -Be 1
        $env:LAB_APPROVED = ''
        Test-LabApproved -Id 'task-1' -Fingerprint '2a2c17aaaf66' | Should -Be 1
        Test-Path -LiteralPath (Get-LabManifestPath) | Should -BeFalse
    }

    It 'approved: an item changed since the plan is refused and recorded' {
        $env:LAB_APPROVED = 'task-1@2a2c17aaaf66'
        Test-LabApproved -Id 'task-1' -Fingerprint '5821d4d89f00' 2> $null | Should -Be 2
        $e = @(Get-LabManifestEntry | Where-Object { $_.action -ceq 'approval_refused' })
        $e.Count | Should -Be 1
        $e[0].target | Should -Be 'task-1'
        $e[0].prev | Should -Be '2a2c17aaaf66'
        $e[0].note | Should -Be 'changed since the plan; now 5821d4d89f00'
    }
}
