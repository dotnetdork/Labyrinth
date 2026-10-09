#Requires -Version 5.1
# Pester 5 unit tests for the Windows core library (core\): configuration
# readers, logger, manifest, safety helpers and probes. Each test gets its
# own configuration, state, log and backup folders under TestDrive.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')

    function Write-TestFile {
        param([string] $Path, [AllowEmptyCollection()] [string[]] $Lines)
        [IO.File]::WriteAllText($Path, (($Lines | ForEach-Object { "$_`n" }) -join ''))
    }
}

Describe 'core library' {
    BeforeEach {
        $base = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $env:LAB_CONFIG_DIR = Join-Path $base 'etc'
        $env:LAB_STATE_DIR = Join-Path $base 'state'
        $env:LAB_LOG_DIR = Join-Path $base 'logs'
        $env:LAB_BACKUP_DIR = Join-Path $base 'backup'
        $env:LAB_RUN_ID = '20261002T120000Z-abcd'
        $env:LAB_MODULE_ID = 'observe.unit'
        $env:LAB_ENTRY = 'apply'
        $env:LAB_DRY_RUN = '0'
        $files = Join-Path $base 'files'
        New-Item -ItemType Directory -Path $env:LAB_CONFIG_DIR, $files -Force | Out-Null
        $protected = Join-Path $env:LAB_CONFIG_DIR 'protected-accounts'
    }

    It 'config: comments, blank lines and whitespace are ignored' {
        Write-TestFile $protected @('# c', '', '  Administrator   breakglass   # reason', "DefaultAccount builtin`r")
        $set = Read-LabProtectedSet
        $set['Administrator'] | Should -Be 'breakglass'
        $set['DefaultAccount'] | Should -Be 'builtin'
        $set.Count | Should -Be 2
    }

    It 'config: a protected set that is missing, empty or malformed' {
        Read-LabProtectedSet | Should -Be $null
        Write-TestFile $protected @('# only a comment')
        Read-LabProtectedSet | Should -Be $null
        Write-TestFile $protected @('Administrator wizard')
        { Read-LabProtectedSet } | Should -Throw
        Write-TestFile $protected @('Administrator breakglass', 'Administrator scoring')
        { Read-LabProtectedSet } | Should -Throw
    }

    It 'config: addresses and CIDRs are checked' {
        foreach ($a in '192.0.2.1', '198.51.100.0/28', '0.0.0.0/0', '2001:db8::1', '2001:db8::/32', '::1', '::', '1:2:3:4:5:6:7:8',
            '1:2:3:4:5:6:7::', '::ffff:192.0.2.1') {
            Test-LabAddress $a | Should -Be $true
        }
        foreach ($a in '256.1.1.1', '1.2.3', '1.2.3.4/33', 'example.test', '2001:db8::/129', '1.2.3.4 ', '', ':::', '1::2::3',
            ':1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '1:2:3:4:5:6:7', '12345::1', '::ffff:1.2.3.256', '-1::1') {
            Test-LabAddress $a | Should -Be $false
        }
        Write-TestFile (Join-Path $env:LAB_CONFIG_DIR 'scoring-allowlist') @('198.51.100.0/28', 'not-an-address')
        { Read-LabAddressList 'scoring-allowlist' } | Should -Throw
        Read-LabAddressList 'never-ban' | Should -Be $null
    }

    It 'config: the service list' {
        $svc = Join-Path $env:LAB_CONFIG_DIR 'services'
        Write-TestFile $svc @('web http www.example.test 80 Welcome', 'dns1 dns ns1.example.test 53 www.example.test=192.0.2.20')
        $list = Read-LabServiceList
        $list.Count | Should -Be 2
        $list[1].Expect | Should -Be 'www.example.test=192.0.2.20'
        $list[0].Port | Should -Be 80
        foreach ($bad in @(, @('web gopher h 70 -')) + @(, @('web http h 70000 -')) + @(, @('web http h 80')) +
            @(, @('d dns h 53 -')) + @(, @('web http h 80 -', 'web http h 81 -')) +
            @(, @('web http -h 80 -')) + @(, @('-web http h 80 -')) + @(, @('web http h 80 -x'))) {
            Write-TestFile $svc $bad
            { Read-LabServiceList } | Should -Throw
        }
        # An empty list, or one with only comments, counts as missing.
        Write-TestFile $svc @('# nothing yet')
        Read-LabServiceList | Should -Be $null
    }

    It 'config: event.conf defaults and range checks' {
        $conf = Join-Path $env:LAB_CONFIG_DIR 'event.conf'
        (Read-LabEventConfig)['REVERT_MINUTES'] | Should -Be 5
        Write-TestFile $conf @('REVERT_MINUTES=7', 'SIEM_ADDRESS=192.0.2.10')
        $s = Read-LabEventConfig
        $s['REVERT_MINUTES'] | Should -Be 7
        $s['SIEM_ADDRESS'] | Should -Be '192.0.2.10'
        Write-TestFile $conf @('REVERT_MINUTES=0')
        { Read-LabEventConfig } | Should -Throw
        Write-TestFile $conf @('revert_minutes=5')
        { Read-LabEventConfig } | Should -Throw
    }

    It 'config: hosts lookup is case-insensitive' {
        $hosts = Join-Path $env:LAB_CONFIG_DIR 'hosts'
        Write-TestFile $hosts @('WEB01 ring1 windows-member windows', 'edge01 manual appliance appliance')
        $h = Find-LabHost 'web01'
        $h.Group | Should -Be 'ring1'
        $h.Profile | Should -Be 'windows-member'
        Find-LabHost 'db01' | Should -Be $null
        Write-TestFile $hosts @('web01 ring1 windows-member beos')
        { Find-LabHost 'web01' } | Should -Throw
    }

    It 'json: escaping round-trips through ConvertFrom-Json' {
        $s = "quote `" back \ tab `t nl `n bell $([char]7) end"
        $json = '{"k":' + (ConvertTo-LabJsonString $s) + '}'
        $json | Should -Match ([regex]::Escape('\u0007'))
        ($json | ConvertFrom-Json).k | Should -Be $s
    }

    It 'log: lines carry the contract fields, and plan mode writes nothing' {
        Write-LabLog -Level info -EventName rule_added -Message 'allowed "tcp/443"'
        $line = (Get-ChildItem -LiteralPath (Join-Path $env:LAB_LOG_DIR 'run') | Get-Content) -join ''
        $line | Should -Match ('^\{"ts":"\d{4}-\d\d-\d\dT[0-9:]{8}Z","host":".+","run":"20261002T120000Z-abcd",' +
            '"module":"observe.unit","entry":"apply","level":"info","event":"rule_added","msg":"allowed \\"tcp/443\\""\}$')
        Remove-Item -LiteralPath $env:LAB_LOG_DIR -Recurse
        $env:LAB_DRY_RUN = '1'
        Write-LabLog -Level info -EventName x -Message 'not written'
        $env:LAB_LOG_DIR | Should -Not -Exist
    }

    It 'manifest: refused in plan mode' {
        $env:LAB_DRY_RUN = '1'
        { Add-LabManifestEntry -Action file -Target 'C:\x' } | Should -Throw
        $env:LAB_STATE_DIR | Should -Not -Exist
    }

    It 'manifest: backup, change and restore, newest first' {
        $f = Join-Path $files 'a.conf'
        [IO.File]::WriteAllText($f, "one`n")
        Backup-LabFile $f
        [IO.File]::WriteAllText($f, "two`n")
        Backup-LabFile $f
        [IO.File]::WriteAllText($f, "three`n")
        $new = Join-Path $files 'new.conf'
        Backup-LabFile $new
        [IO.File]::WriteAllText($new, "created`n")
        @(Get-LabManifestEntry).Count | Should -Be 3
        Restore-LabBackup
        (Get-Content -LiteralPath $f) | Should -Be 'one'
        $new | Should -Not -Exist
        Join-Path $env:LAB_BACKUP_DIR "$env:LAB_RUN_ID\observe.unit\rolled-back-3-new.conf" | Should -Exist
        Restore-LabBackup
        (Get-Content -LiteralPath $f) | Should -Be 'one'
    }

    It "manifest: only the module's own entries are restored" {
        $f = Join-Path $files 'b.conf'
        [IO.File]::WriteAllText($f, "orig`n")
        $env:LAB_MODULE_ID = 'observe.other'
        Backup-LabFile $f
        $env:LAB_MODULE_ID = 'observe.unit'
        [IO.File]::WriteAllText($f, "changed`n")
        Restore-LabBackup
        (Get-Content -LiteralPath $f) | Should -Be 'changed'
    }

    It 'manifest: relative paths and directories are refused' {
        { Backup-LabFile 'relative.conf' } | Should -Throw
        { Backup-LabFile $files } | Should -Throw
    }

    It 'manifest: applied modules, minus the ones rolled back' {
        foreach ($m in 'observe.a', 'observe.b', 'observe.c') {
            $env:LAB_MODULE_ID = $m
            Add-LabManifestEntry -Action apply_start
        }
        $env:LAB_MODULE_ID = 'observe.b'
        Add-LabManifestEntry -Action rolled_back
        (Get-LabAppliedModule -RunId $env:LAB_RUN_ID) -join ' ' | Should -Be 'observe.a observe.c'
    }

    It 'safety: break-glass must be a breakglass account and is remembered' {
        Write-TestFile $protected @('Administrator breakglass', 'scorer scoring')
        $set = Read-LabProtectedSet
        { Save-LabBreakGlass -Protected $set -Account 'scorer' } | Should -Throw
        Get-LabBreakGlass -Protected $set | Should -Be $null
        Save-LabBreakGlass -Protected $set -Account 'Administrator'
        Get-LabBreakGlass -Protected $set | Should -Be 'Administrator'
        Write-TestFile $protected @('Administrator scoring')
        Get-LabBreakGlass -Protected (Read-LabProtectedSet) | Should -Be $null
    }

    It 'safety: the run lock' {
        Enter-LabLock | Should -Be $true
        ([IO.File]::ReadAllText((Join-Path $env:LAB_STATE_DIR 'lock\pid'))).Trim() | Should -Be "$PID"
        # This process holds it, but a second taker never gets it.
        [IO.File]::WriteAllText((Join-Path $env:LAB_STATE_DIR 'lock\pid'), "$((Get-Process -Id $PID).Id)`n")
        Exit-LabLock
        Join-Path $env:LAB_STATE_DIR 'lock' | Should -Not -Exist
        New-Item -ItemType Directory -Path (Join-Path $env:LAB_STATE_DIR 'lock') | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:LAB_STATE_DIR 'lock\pid'), "$((Get-Process -Name System).Id)`n")
        Enter-LabLock | Should -Be $false
        Remove-Item -LiteralPath (Join-Path $env:LAB_STATE_DIR 'lock') -Recurse
    }

    It 'safety: the data root is private to administrators, SYSTEM and this account' {
        $trusted = @(Get-LabTrustedSid)
        $new = Join-Path $base 'root-new'
        $old = Join-Path $base 'root-old'
        New-Item -ItemType Directory -Path (Join-Path $old 'etc') -Force | Out-Null
        Write-TestFile (Join-Path $old 'etc\hosts') @('kept')
        foreach ($root in $new, $old) {
            Protect-LabDataRoot -Path $root
            $acl = Get-Acl -LiteralPath $root
            $acl.AreAccessRulesProtected | Should -Be $true
            $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
            @($sids | Where-Object { $trusted -notcontains $_ }) -join ' ' | Should -Be ''
        }
        Get-Content -LiteralPath (Join-Path $old 'etc\hosts') | Should -Be 'kept'
        # Files inside inherit the private access list.
        $fileAcl = Get-Acl -LiteralPath (Join-Path $old 'etc\hosts')
        $sids = @($fileAcl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
        @($sids | Where-Object { $trusted -notcontains $_ }) -join ' ' | Should -Be ''
    }

    It 'safety: code and data that an account other than an administrator can change are found' {
        $dir = Join-Path $base 'code'
        New-Item -ItemType Directory -Path (Join-Path $dir 'core') -Force | Out-Null
        $f = Join-Path $dir 'core\lib.ps1'
        Write-TestFile $f @('x')
        Find-LabUntrustedItem -Path @($dir, '', (Join-Path $base 'not-made\etc')) | Should -BeNullOrEmpty
        # Authenticated Users may change one file.
        $acl = Get-Acl -LiteralPath $f
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier 'S-1-5-11'), 'Modify', 'Allow')))
        Set-Acl -LiteralPath $f -AclObject $acl
        Find-LabUntrustedItem -Path $dir | Should -BeLike '*\code\core\lib.ps1'
    }

    It 'safety: the owner of the system drive (TrustedInstaller) is trusted' {
        $owner = (Get-Acl -LiteralPath "$env:SystemDrive\").GetOwner([Security.Principal.SecurityIdentifier]).Value
        @(Get-LabAdminSid) | Should -Contain $owner
    }

    It 'safety: a junction planted in the lock folder is never followed' {
        $target = Join-Path $base 'precious'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Write-TestFile (Join-Path $target 'keep') @('x')
        Enter-LabLock | Should -Be $true
        $lock = Join-Path $env:LAB_STATE_DIR 'lock'
        New-Item -ItemType Junction -Path (Join-Path $lock 'j') -Value $target | Out-Null
        { Exit-LabLock } | Should -Throw
        Join-Path $target 'keep' | Should -Exist
        [IO.Directory]::Delete((Join-Path $lock 'j'))
        [IO.Directory]::Delete($lock)
        Join-Path $target 'keep' | Should -Exist
    }

    It 'safety: the console check answers for an account with no session' {
        $s = Get-LabConsoleSession -Account 'lab-no-such-account'
        ($null -eq $s -or $s -eq 'unknown') | Should -BeTrue
    }

    It 'safety: revert-timer arguments survive a real command line' {
        $script = Join-Path $base 'args.ps1'
        [IO.File]::WriteAllText($script, '$args | ForEach-Object { "<$_>" }')
        $values = @('C:\Labyrinth\', 'C:\', 'C:\Program Files\Lab', 'C:\two\\')
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File {0} {1}' -f (ConvertTo-LabCommandLineArgument $script),
            (($values | ForEach-Object { ConvertTo-LabCommandLineArgument $_ }) -join ' ')
        $psi = New-Object Diagnostics.ProcessStartInfo((Get-Process -Id $PID).Path, $line)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        (($out.Trim() -split '\r?\n') -join '|') | Should -Be (($values | ForEach-Object { "<$_>" }) -join '|')
        $threw = $false
        try { ConvertTo-LabCommandLineArgument 'a"b' } catch { $threw = $true }
        $threw | Should -Be $true
    }

    It 'timer: a failed re-arm leaves the earlier timer armed' {
        # Stand-ins for the scheduled-task cmdlets, in this test's scope only.
        # The module is loaded first: loading it later would replace them.
        Import-Module ScheduledTasks
        $removed = Join-Path $base 'removed'
        $dir = Get-LabRunDir $env:LAB_RUN_ID
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'timer-count'), "1`n")
        [IO.File]::WriteAllText((Join-Path $dir 'timer'), "lab-revert-$($env:LAB_RUN_ID)-1`n")
        Set-Item -Path function:Unregister-ScheduledTask -Value ([scriptblock]::Create(
                "param(`$TaskName) Add-Content -LiteralPath '$removed' -Value `$TaskName"))
        Set-Item -Path function:Register-ScheduledTask -Value { throw 'refused' }
        # Never reach the real cmdlets: they would register a task.
        foreach ($c in 'Register-ScheduledTask', 'Unregister-ScheduledTask') {
            [string](Get-Command $c).Module | Should -Be ''
        }
        try {
            $threw = $false
            try { Register-LabRevertTimer -Seconds 60 -RunId $env:LAB_RUN_ID -Execute 'cmd.exe' -Argument '/c rem' } catch { $threw = $true }
            $threw | Should -Be $true
            ([IO.File]::ReadAllText((Join-Path $dir 'timer'))).Trim() | Should -Be "lab-revert-$($env:LAB_RUN_ID)-1"
            $removed | Should -Not -Exist
            # A re-arm that works removes the earlier timer only afterwards.
            Set-Item -Path function:Register-ScheduledTask -Value { }
            Register-LabRevertTimer -Seconds 60 -RunId $env:LAB_RUN_ID -Execute 'cmd.exe' -Argument '/c rem'
            ([IO.File]::ReadAllText((Join-Path $dir 'timer'))).Trim() | Should -Be "lab-revert-$($env:LAB_RUN_ID)-2"
            (Get-Content -LiteralPath $removed) | Should -Be "lab-revert-$($env:LAB_RUN_ID)-1"
        } finally {
            # The stand-ins outlive this test otherwise, and later test files
            # would reach them instead of the real cmdlets.
            Remove-Item -Path function:Register-ScheduledTask, function:Unregister-ScheduledTask -ErrorAction SilentlyContinue
            Import-Module ScheduledTasks -Force
        }
    }

    It 'timer: the due time is kept in UTC and a malformed one is unknown' {
        $dir = Get-LabRunDir $env:LAB_RUN_ID
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $at = [datetime]::new(2030, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        Save-LabRevertTimerDue -RunId $env:LAB_RUN_ID -At $at
        Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID | Should -Be '2030-01-02T03:04:05Z'
        [IO.File]::WriteAllText((Join-Path $dir 'timer-due'), "soon`n")
        Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID | Should -Be ''
        Remove-Item -LiteralPath (Join-Path $dir 'timer-due')
        Get-LabRevertTimerDue -RunId $env:LAB_RUN_ID | Should -Be ''
    }

    It 'timer: a timer still there after removal is not cancelled' {
        # Stand-ins, as in the re-arm test above.
        Import-Module ScheduledTasks
        $dir = Get-LabRunDir $env:LAB_RUN_ID
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'timer'), "lab-revert-$($env:LAB_RUN_ID)-1`n")
        [IO.File]::WriteAllText((Join-Path $dir 'timer-due'), "2030-01-02T03:04:05Z`n")
        Set-Item -Path function:Unregister-ScheduledTask -Value { }
        Set-Item -Path function:Get-ScheduledTask -Value { 'still here' }
        foreach ($c in 'Unregister-ScheduledTask', 'Get-ScheduledTask') {
            [string](Get-Command $c).Module | Should -Be ''
        }
        try {
            $msg = ''
            try { Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID } catch { $msg = $_.Exception.Message }
            $msg | Should -Match 'could not be removed'
            Join-Path $dir 'timer' | Should -Exist
            Join-Path $dir 'timer-due' | Should -Exist
            # Once the task is gone, both files go.
            Set-Item -Path function:Get-ScheduledTask -Value { }
            Unregister-LabRevertTimer -RunId $env:LAB_RUN_ID
            Join-Path $dir 'timer' | Should -Not -Exist
            Join-Path $dir 'timer-due' | Should -Not -Exist
        } finally {
            Remove-Item -Path function:Unregister-ScheduledTask, function:Get-ScheduledTask -ErrorAction SilentlyContinue
            Import-Module ScheduledTasks -Force
        }
    }

    It 'probe: a closed port fails' {
        Invoke-LabProbe -Proto tcp -Target 127.0.0.1 -Port 1 -Expect '-' -Timeout 2 | Should -Be 'fail no connection'
        Invoke-LabProbe -Proto smtp -Target 127.0.0.1 -Port 1 -Expect '-' -Timeout 2 | Should -Be 'fail no banner'
    }

    It 'probe: an HTTP status line and body are checked' {
        Get-LabHttpResult '200' '<h1>Welcome</h1>' 'Welcome' | Should -Be 'pass status 200'
        Get-LabHttpResult '200' 'other' 'Welcome' | Should -Match '^fail'
        Get-LabHttpResult '503' 'oops' '-' | Should -Be 'fail status 503'
    }

    It 'probe: regressions are pass before and fail after only' {
        $before = @('web pass status 200', 'mail pass banner', 'dns unknown no tool', 'ftp fail no banner')
        $after = @('web fail status 503', 'mail pass banner', 'dns fail x', 'ftp fail no banner')
        @(Get-LabProbeRegression -Before $before -After $after) -join ' ' | Should -Be 'web'
    }

    It 'probe: Get-LabProbeResult reports every listed service' {
        Write-TestFile (Join-Path $env:LAB_CONFIG_DIR 'services') @('a tcp 127.0.0.1 1 -', 'b tcp 127.0.0.1 1 -')
        $out = Get-LabProbeResult -Timeout 2
        $out.Count | Should -Be 2
        $out[0] | Should -Match '^a fail'
        Remove-Item -LiteralPath (Join-Path $env:LAB_CONFIG_DIR 'services')
        Get-LabProbeResult | Should -Be $null
    }
}
