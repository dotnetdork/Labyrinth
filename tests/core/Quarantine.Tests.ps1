#Requires -Version 5.1
# Pester 5 unit tests for the quarantine helper (core\quarantine\
# Quarantine.ps1, design 06, section 5.1). Files and registry values are real,
# under TestDrive: and TestRegistry:; scheduled tasks and services are mocked.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')

    function Get-TestEntry {
        param([string] $Action)
        return @(Get-LabManifestEntry | Where-Object { $_.action -ceq $Action })
    }
}

Describe 'quarantine' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LAB_CONFIG_DIR = Join-Path $root 'etc'
        $env:LAB_STATE_DIR = Join-Path $root 'state'
        $env:LAB_BACKUP_DIR = Join-Path $root 'backup'
        $env:LAB_LOG_DIR = Join-Path $root 'logs'
        $env:LAB_RUN_ID = '20261005T120000Z-abcd'
        $env:LAB_MODULE_ID = 'lockout.persistence'
        $env:LAB_DRY_RUN = '0'
        $items = Join-Path $root 'host'
        New-Item -ItemType Directory -Path $items -Force | Out-Null
    }

    It 'file: moved aside with its hash and restored byte for byte' {
        $f = Join-Path $items 'sethc.exe'
        [IO.File]::WriteAllBytes($f, [byte[]](1, 2, 3, 250))
        $sum = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
        Move-LabQuarantineFile -Path $f -Reason 'replaced accessibility program' | Should -Be 0
        Test-Path -LiteralPath $f | Should -BeFalse
        $e = @(Get-TestEntry 'quarantine_file')[0]
        # The hash, then the file's owner and access list.
        $e.prev | Should -BeLike "$sum O:*"
        $e.note | Should -Be 'replaced accessibility program'
        $e.backup | Should -BeLike (Join-Path $env:LAB_BACKUP_DIR "quarantine\$env:LAB_RUN_ID\1\*")
        Undo-LabQuarantine | Should -Be 0
        (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $sum
        Undo-LabQuarantine | Should -Be 0
    }

    It 'file: the quarantined copy is private to administrators, and the restore brings back the owner and access list' {
        $sidType = [Security.Principal.SecurityIdentifier]
        $f = Join-Path $items 'open.ps1'
        [IO.File]::WriteAllText($f, 'planted')
        # Another account owns the file, and every user may change it.
        $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        $acl = [IO.File]::GetAccessControl($f)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'Allow')))
        [IO.File]::SetAccessControl($f, $acl)
        Invoke-LabFileOwner -Path $f -Sid 'S-1-5-32-545'
        [IO.File]::GetAccessControl($f).GetOwner($sidType).Value | Should -Be 'S-1-5-32-545'

        Move-LabQuarantineFile -Path $f -Reason test | Should -Be 0
        $copy = @(Get-TestEntry 'quarantine_file')[0].backup
        $kept = [IO.File]::GetAccessControl($copy)
        $kept.GetOwner($sidType).Value | Should -Be 'S-1-5-32-544'
        $kept.AreAccessRulesProtected | Should -BeTrue
        $who = @($kept.GetAccessRules($true, $true, $sidType) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        ($who -join ',') | Should -Be 'S-1-5-18,S-1-5-32-544'

        # A newer file at the path, also open to every user, is moved aside private too.
        [IO.File]::WriteAllText($f, 'replanted')
        $acl = [IO.File]::GetAccessControl($f)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'Modify', 'Allow')))
        [IO.File]::SetAccessControl($f, $acl)
        Undo-LabQuarantine | Should -Be 0
        [IO.File]::ReadAllText($f) | Should -Be 'planted'
        $back = [IO.File]::GetAccessControl($f)
        $back.GetOwner($sidType).Value | Should -Be 'S-1-5-32-545'
        $modify = [int][Security.AccessControl.FileSystemRights]::Modify
        @($back.GetAccessRules($true, $false, $sidType) | Where-Object {
                $_.IdentityReference.Value -ceq 'S-1-5-32-545' -and $_.AccessControlType -eq 'Allow' -and
                ([int]$_.FileSystemRights -band $modify) -eq $modify }).Count | Should -Be 1
        $aside = @(Get-ChildItem -Recurse -File (Get-LabQuarantineDir) | Where-Object { $_.FullName -like '*aside-1*' })[0].FullName
        $moved = [IO.File]::GetAccessControl($aside)
        $moved.GetOwner($sidType).Value | Should -Be 'S-1-5-32-544'
        @($moved.GetAccessRules($true, $true, $sidType) | Where-Object { $_.IdentityReference.Value -ceq 'S-1-5-32-545' }).Count | Should -Be 0
    }

    It 'file: refused in plan mode, for a folder, a relative path or Labyrinth''s own tree' {
        $f = Join-Path $items 'a.ps1'
        [IO.File]::WriteAllText($f, 'x')
        New-Item -ItemType Directory -Path $env:LAB_STATE_DIR -Force | Out-Null
        $own = Join-Path $env:LAB_STATE_DIR 's'
        [IO.File]::WriteAllText($own, 'x')
        foreach ($p in @($items, 'host\a.ps1', "$items\..\host\a.ps1", $own)) {
            Move-LabQuarantineFile -Path $p -Reason test | Should -Be 20
        }
        $env:LAB_DRY_RUN = '1'
        Move-LabQuarantineFile -Path $f -Reason test | Should -Be 20
        Test-Path -LiteralPath $f | Should -BeTrue
        Test-Path -LiteralPath (Get-LabManifestPath) | Should -BeFalse
    }

    It 'file: restore moves a newer file aside and refuses a changed copy' {
        $f = Join-Path $items 'x.ps1'
        [IO.File]::WriteAllText($f, 'planted')
        Move-LabQuarantineFile -Path $f -Reason test | Should -Be 0
        [IO.File]::WriteAllText($f, 'replanted')
        Undo-LabQuarantine | Should -Be 0
        [IO.File]::ReadAllText($f) | Should -Be 'planted'
        @(Get-ChildItem -Recurse -File (Get-LabQuarantineDir) | Where-Object { $_.FullName -like '*aside-1*' }).Count | Should -Be 1

        $g = Join-Path $items 'y.ps1'
        [IO.File]::WriteAllText($g, 'planted')
        Move-LabQuarantineFile -Path $g -Reason test | Should -Be 0
        [IO.File]::WriteAllText(@(Get-TestEntry 'quarantine_file')[1].backup, 'tampered')
        Undo-LabQuarantine | Should -Be 40
        Test-Path -LiteralPath $g | Should -BeFalse
    }

    It 'file: one that cannot be moved is left for a person (20), not an error' {
        $f = Join-Path $items 'locked.exe'
        [IO.File]::WriteAllText($f, 'x')
        $lock = [IO.File]::Open($f, 'Open', 'Read', 'None')
        try {
            Move-LabQuarantineFile -Path $f -Reason test 2> $null | Should -Be 20
        } finally {
            $lock.Dispose()
        }
        Test-Path -LiteralPath $f | Should -BeTrue
        Undo-LabQuarantine | Should -Be 0
        Test-Path -LiteralPath $f | Should -BeTrue
    }

    It 'manifest: control characters in an item are kept, escaped' {
        $line = "*`t*`t*`t*`t*`troot`t/tmp/.x"
        Add-LabManifestEntry -Action quarantine_cron -Target 'C:\x' -Prev $line
        @(Get-TestEntry 'quarantine_cron')[0].prev | Should -BeExactly $line
    }

    It 'registry: a value is exported, removed and put back with its kind' {
        $key = 'TestRegistry:\Run'
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Updater' -PropertyType ExpandString -Value '%TEMP%\u.exe' | Out-Null
        New-ItemProperty -Path $key -Name 'Blob' -PropertyType Binary -Value ([byte[]](0, 1, 255)) | Out-Null
        Move-LabQuarantineRegistryValue -Path $key -Name 'Updater' -Reason 'runs from a temporary folder' | Should -Be 0
        Move-LabQuarantineRegistryValue -Path $key -Name 'Blob' -Reason test | Should -Be 0
        (Get-Item $key).GetValueNames() | Should -Not -Contain 'Updater'
        Move-LabQuarantineRegistryValue -Path $key -Name 'Updater' -Reason test | Should -Be 0
        @(Get-TestEntry 'quarantine_registry').Count | Should -Be 2
        Undo-LabQuarantine | Should -Be 0
        $k = Get-Item $key
        $k.GetValueKind('Updater') | Should -Be 'ExpandString'
        $k.GetValue('Updater', $null, 'DoNotExpandEnvironmentNames') | Should -Be '%TEMP%\u.exe'
        $k.GetValueKind('Blob') | Should -Be 'Binary'
        $k.GetValue('Blob') | Should -Be ([byte[]](0, 1, 255))
    }

    It 'registry: the Winlogon values every logon needs are refused' {
        Mock Remove-ItemProperty { }
        Move-LabQuarantineRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'Userinit' -Reason test | Should -Be 20
        Move-LabQuarantineRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\' -Name 'Shell' -Reason test | Should -Be 20
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'service: start mode recorded, disabled and stopped, then brought back' {
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'Updater'; StartMode = 'Auto'; DelayedAutoStart = $false; State = 'Running' } } -ParameterFilter { $ClassName -eq 'Win32_Service' }
        Mock Set-Service { }
        Mock Stop-Service { }
        Mock Start-Service { }
        Disable-LabQuarantineService -Name 'Updater' -Reason 'binary in a temporary folder' | Should -Be 0
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $StartupType -eq 'Disabled' }
        Should -Invoke Stop-Service -Times 1 -Exactly
        @(Get-TestEntry 'quarantine_service')[0].prev | Should -Be 'start=Auto delayed=False running=True'
        Undo-LabQuarantine | Should -Be 0
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $StartupType -eq 'Automatic' }
        Should -Invoke Start-Service -Times 1 -Exactly
    }

    It 'task: exported to XML, disabled, then enabled again' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Upd'; State = 'Ready' } }
        Mock Export-ScheduledTask { '<Task />' }
        Mock Disable-ScheduledTask { }
        Mock Enable-ScheduledTask { }
        Mock Register-ScheduledTask { }
        Disable-LabQuarantineTask -TaskPath '\' -TaskName 'Upd' -Reason test | Should -Be 0
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
        $e = @(Get-TestEntry 'quarantine_task')[0]
        $e.target | Should -Be '\Upd'
        [IO.File]::ReadAllText($e.backup) | Should -Be '<Task />'
        Undo-LabQuarantine | Should -Be 0
        Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' -and $TaskName -eq 'Upd' }
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }

    It 'WMI: a binding that is not there is nothing to do' {
        Mock Get-CimInstance { @() } -ParameterFilter { $ClassName -eq '__FilterToConsumerBinding' }
        Mock Remove-CimInstance { }
        Move-LabQuarantineWmiBinding -FilterName 'f' -ConsumerName 'c' -Reason test | Should -Be 0
        Should -Invoke Remove-CimInstance -Times 0 -Exactly
        Test-Path -LiteralPath (Get-LabManifestPath) | Should -BeFalse
    }

    It 'process: ended and recorded; never Labyrinth itself or the system' {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
        try {
            Invoke-LabQuarantineProcess -Id $p.Id -Reason 'started by a quarantined task' | Should -Be 0
            $p.WaitForExit(10000) | Should -BeTrue
            @(Get-TestEntry 'quarantine_process')[0].prev | Should -BeLike '*Start-Sleep*'
        } finally {
            if (-not $p.HasExited) { $p.Kill() }
        }
        Invoke-LabQuarantineProcess -Id $PID -Reason test | Should -Be 20
        Invoke-LabQuarantineProcess -Id 4 -Reason test | Should -Be 20
        $env:LAB_DRY_RUN = '1'
        Invoke-LabQuarantineProcess -Id 999999 -Reason test | Should -Be 20
    }
}
