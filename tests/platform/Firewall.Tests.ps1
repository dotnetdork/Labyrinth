#Requires -Version 5.1
# Pester 5 unit tests for the Windows Firewall adapter (platform\windows\
# Firewall.ps1, design 19, section 5). netsh and the NetSecurity cmdlets are
# mocked, so no real firewall is read or changed.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
    . (Join-Path $env:LAB_ROOT 'platform\windows\Firewall.ps1')

    function Get-TestManifestAction {
        return @(Get-LabManifestEntry | ForEach-Object { $_.action })
    }
}

Describe 'Windows Firewall adapter' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LAB_CONFIG_DIR = Join-Path $root 'etc'
        $env:LAB_STATE_DIR = Join-Path $root 'state'
        $env:LAB_BACKUP_DIR = Join-Path $root 'backup'
        $env:LAB_LOG_DIR = Join-Path $root 'logs'
        $env:LAB_RUN_ID = '20261005T120000Z-abcd'
        $env:LAB_MODULE_ID = 'lockout.firewall'
        $env:LAB_DRY_RUN = '0'
        New-Item -ItemType Directory -Path $env:LAB_CONFIG_DIR -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:LAB_CONFIG_DIR 'scoring-allowlist'), "198.51.100.7`n2001:db8::7`n")

        Mock Get-LabFact { 'on' } -ParameterFilter { $Name -eq 'firewall' }
        Mock Invoke-LabNetsh {
            if ($Argument[1] -eq 'export') { [IO.File]::WriteAllText($Argument[2], 'wfw') }
        }
        Mock Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True'; DefaultInboundAction = 'NotConfigured'; DefaultOutboundAction = 'NotConfigured'; AllowInboundRules = 'NotConfigured' }) }
        Mock Get-NetFirewallPortFilter { @([pscustomobject]@{ InstanceID = 'r1'; Protocol = 'TCP'; LocalPort = @('3389') }) }
        Mock Get-NetFirewallAddressFilter { @([pscustomobject]@{ InstanceID = 'r1'; RemoteAddress = @('Any') }) }
        Mock Get-NetFirewallRule { @([pscustomobject]@{ Name = 'r1'; Enabled = 'True'; Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any' }) }
        Mock New-NetFirewallRule { }
        Mock Set-NetFirewallProfile { }
    }

    It 'allow and default deny are refused before a snapshot' {
        Add-LabFirewallAllow -Protocol tcp -Port 443 -Source '198.51.100.7' | Should -Be 20
        Enable-LabFirewallDefaultDeny | Should -Be 20
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
    }

    It 'nothing changes in plan mode' {
        $env:LAB_DRY_RUN = '1'
        Save-LabFirewallSnapshot | Should -Be 20
        Add-LabFirewallAllow -Protocol tcp -Port 443 -Source any | Should -Be 20
        Enable-LabFirewallDefaultDeny | Should -Be 20
        Should -Invoke Invoke-LabNetsh -Times 0 -Exactly
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
    }

    It 'every change is refused when the firewall state is unknown' {
        Mock Get-LabFact { 'unknown' } -ParameterFilter { $Name -eq 'firewall' }
        Save-LabFirewallSnapshot | Should -Be 20
        Should -Invoke Invoke-LabNetsh -Times 0 -Exactly
    }

    It 'bad arguments are errors' {
        Save-LabFirewallSnapshot | Should -Be 0
        Add-LabFirewallAllow -Protocol icmp -Port 1 -Source any | Should -Be 40
        Add-LabFirewallAllow -Protocol tcp -Port 70000 -Source any | Should -Be 40
        Add-LabFirewallAllow -Protocol tcp -Port 22 -Source 'not-an-address' | Should -Be 40
        Restore-LabFirewallSnapshot -Path (Join-Path $TestDrive 'nothing') | Should -Be 40
        Should -Invoke New-NetFirewallRule -Times 0 -Exactly
    }

    It 'snapshot, allows, then default deny, each recorded before it is made' {
        Save-LabFirewallSnapshot | Should -Be 0
        $dir = @(Get-LabFirewallSnapshotList)[0]
        Test-Path -LiteralPath (Join-Path $dir 'firewall.wfw') | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $dir 'state')) | Should -Match 'rule r1 enabled=True Inbound Allow profile=Any ports=TCP 3389 from=Any'

        Add-LabFirewallAllow -Protocol tcp -Port 443 -Source '198.51.100.7' | Should -Be 0
        Add-LabFirewallAllow -Protocol tcp -Port 443 -Source '198.51.100.7' | Should -Be 0
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            $Direction -eq 'Inbound' -and $Action -eq 'Allow' -and $Protocol -eq 'TCP' -and $LocalPort -eq '443' -and $RemoteAddress -eq '198.51.100.7' -and $Group -eq 'Labyrinth'
        }

        Enable-LabFirewallDefaultDeny | Should -Be 20
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly

        Add-LabFirewallAllow -Protocol udp -Port 53 -Source '2001:db8::7' | Should -Be 0
        Mock Get-NetFirewallRule { $null } -ParameterFilter { $DisplayName -like 'Labyrinth: allow ICMP*' }
        Enable-LabFirewallDefaultDeny | Should -Be 0
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Protocol -eq 'ICMPv4' }
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $Protocol -eq 'ICMPv6' }
        Should -Invoke Set-NetFirewallProfile -Times 1 -Exactly -ParameterFilter {
            $DefaultInboundAction -eq 'Block' -and $Enabled -eq 'True' -and $AllowInboundRules -eq 'True'
        }
        (Get-TestManifestAction) -join ' ' | Should -Be 'firewall_snapshot firewall_allow firewall_allow firewall_default_deny'
    }

    It 'default deny needs each scored service''s port allowed from every scoring address' {
        $me = Get-LabHostName
        [IO.File]::WriteAllText((Join-Path $env:LAB_CONFIG_DIR 'services'),
            "web-main http $me 80 Welcome`ndns-main dns $me 53 www.example.test=192.0.2.20`nmail-smtp smtp other.example.test 25 -`n")
        Mock Get-LabLocalAddress { @('192.0.2.250') }
        Save-LabFirewallSnapshot | Should -Be 0
        Add-LabFirewallAllow -Protocol tcp -Port 22 -Source '198.51.100.7' | Should -Be 0
        Add-LabFirewallAllow -Protocol tcp -Port 22 -Source '2001:db8::7' | Should -Be 0
        Mock Write-LabFirewallError { }
        Enable-LabFirewallDefaultDeny | Should -Be 20
        Should -Invoke Write-LabFirewallError -Times 1 -Exactly -ParameterFilter {
            $Message -match 'web-main tcp/80 from 198\.51\.100\.7' -and $Message -match 'dns-main udp/53 from 2001:db8::7' -and
            $Message -notmatch 'mail-smtp'
        }
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
        Add-LabFirewallAllow -Protocol tcp -Port 80 -Source any | Should -Be 0
        Add-LabFirewallAllow -Protocol tcp -Port 53 -Source any | Should -Be 0
        Enable-LabFirewallDefaultDeny | Should -Be 20
        Add-LabFirewallAllow -Protocol udp -Port 53 -Source any | Should -Be 0
        Enable-LabFirewallDefaultDeny | Should -Be 0
        Should -Invoke Set-NetFirewallProfile -Times 1 -Exactly
    }

    It 'with no scored service here, an allow from any covers every scoring address' {
        Save-LabFirewallSnapshot | Should -Be 0
        Add-LabFirewallAllow -Protocol tcp -Port 80 -Source any | Should -Be 0
        Enable-LabFirewallDefaultDeny | Should -Be 0
    }

    It 'default deny is refused without a scoring allowlist' {
        Remove-Item -LiteralPath (Join-Path $env:LAB_CONFIG_DIR 'scoring-allowlist')
        Save-LabFirewallSnapshot | Should -Be 0
        Enable-LabFirewallDefaultDeny | Should -Be 20
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
    }

    It 'rollback imports the snapshot and checks the state' {
        Save-LabFirewallSnapshot | Should -Be 0
        $dir = @(Get-LabFirewallSnapshotList)[0]
        Undo-LabFirewallChange | Should -Be 0
        Should -Invoke Invoke-LabNetsh -Times 1 -Exactly -ParameterFilter { $Argument[1] -eq 'import' -and $Argument[2] -eq (Join-Path $dir 'firewall.wfw') }
        Undo-LabFirewallChange | Should -Be 0
    }

    It 'a restore that does not give back the saved state is reported' {
        Save-LabFirewallSnapshot | Should -Be 0
        Mock Get-NetFirewallRule { @() }
        Undo-LabFirewallChange | Should -Be 30
    }

    It 'a snapshot never overwrites a folder in use' {
        $dir = Join-Path $TestDrive 'used'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'x'), 'x')
        Save-LabFirewallSnapshot -Path $dir | Should -Be 40
    }
}
