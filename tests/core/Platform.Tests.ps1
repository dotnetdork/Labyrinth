#Requires -Version 5.1
# Pester 5 unit tests for the Windows platform facts (core\platform\
# Platform.ps1, design 19). The CIM, firewall, Secure Boot, module and
# service cmdlets are mocked, so no real host setting is read.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $env:LAB_ROOT = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')

    # Use-TestHost -ProductType N [-PartOfDomain]: mock the two CIM classes.
    # The mock bodies are built as text, because Pester runs a mock body in
    # its own scope, where this function's variables are not visible.
    function Use-TestHost {
        param([int] $ProductType, [switch] $PartOfDomain)
        $os = "[pscustomobject]@{ Caption = 'Microsoft Windows Server 2022 Standard'; BuildNumber = '20348'; ProductType = $ProductType }"
        $cs = "[pscustomobject]@{ PartOfDomain = `$$([bool]$PartOfDomain) }"
        Mock Get-CimInstance ([scriptblock]::Create($os)) -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        Mock Get-CimInstance ([scriptblock]::Create($cs)) -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
    }
}

Describe 'platform facts' {
    BeforeEach {
        Clear-LabFact
        Mock Get-NetFirewallProfile {
            @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' },
                [pscustomobject]@{ Name = 'Private'; Enabled = 'True' },
                [pscustomobject]@{ Name = 'Public'; Enabled = 'True' })
        }
        Mock Confirm-SecureBootUEFI { $true }
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'SplunkForwarder' }
    }

    It 'role: a domain controller, member server, standalone server and workstation' {
        Use-TestHost -ProductType 2
        Get-LabFact -Name role | Should -Be 'domain-controller'
        Clear-LabFact
        Use-TestHost -ProductType 3 -PartOfDomain
        Get-LabFact -Name role | Should -Be 'member-server'
        Clear-LabFact
        Use-TestHost -ProductType 3
        Get-LabFact -Name role | Should -Be 'standalone-server'
        Clear-LabFact
        Use-TestHost -ProductType 1 -PartOfDomain
        Get-LabFact -Name role | Should -Be 'workstation'
    }

    It 'os: caption and build come from Win32_OperatingSystem' {
        Use-TestHost -ProductType 3
        Get-LabFact -Name os_caption | Should -Be 'Microsoft Windows Server 2022 Standard'
        Get-LabFact -Name os_build | Should -Be '20348'
    }

    It 'os and role: unknown when CIM cannot be read' {
        Mock Get-CimInstance { throw 'access denied' }
        Get-LabFact -Name os_build | Should -Be 'unknown'
        Get-LabFact -Name role | Should -Be 'unknown'
    }

    It 'firewall: on, partial, off and unknown' {
        Get-LabFact -Name firewall | Should -Be 'on'
        Clear-LabFact
        Mock Get-NetFirewallProfile {
            @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Public'; Enabled = 'False' })
        }
        Get-LabFact -Name firewall | Should -Be 'partial'
        Clear-LabFact
        Mock Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Domain'; Enabled = 'False' }) }
        Get-LabFact -Name firewall | Should -Be 'off'
        Clear-LabFact
        Mock Get-NetFirewallProfile { throw 'service stopped' }
        Get-LabFact -Name firewall | Should -Be 'unknown'
    }

    It 'secure boot: on, off, unsupported without UEFI, unknown on another error' {
        Get-LabFact -Name secure_boot | Should -Be 'on'
        Clear-LabFact
        Mock Confirm-SecureBootUEFI { $false }
        Get-LabFact -Name secure_boot | Should -Be 'off'
        Clear-LabFact
        Mock Confirm-SecureBootUEFI { throw (New-Object System.PlatformNotSupportedException 'Cmdlet not supported on this platform') }
        Get-LabFact -Name secure_boot | Should -Be 'unsupported'
        Clear-LabFact
        Mock Confirm-SecureBootUEFI { throw (New-Object System.UnauthorizedAccessException 'Access was denied') }
        Get-LabFact -Name secure_boot | Should -Be 'unknown'
    }

    It 'ad_module and splunk_forwarder: yes only when present' {
        Get-LabFact -Name ad_module | Should -Be 'no'
        Get-LabFact -Name splunk_forwarder | Should -Be 'no'
        Clear-LabFact
        Mock Get-Module { [pscustomobject]@{ Name = 'ActiveDirectory' } } -ParameterFilter { $Name -eq 'ActiveDirectory' }
        Mock Get-Service { [pscustomobject]@{ Name = 'SplunkForwarder' } } -ParameterFilter { $Name -eq 'SplunkForwarder' }
        Get-LabFact -Name ad_module | Should -Be 'yes'
        Get-LabFact -Name splunk_forwarder | Should -Be 'yes'
    }

    It 'every fact, in order, and kept until cleared' {
        Use-TestHost -ProductType 2
        $all = Get-LabFact
        @($all.Keys) | Should -Be @('os_caption', 'os_build', 'role', 'firewall', 'secure_boot', 'ad_module', 'splunk_forwarder')
        $all['role'] | Should -Be 'domain-controller'
        Use-TestHost -ProductType 1
        Get-LabFact -Name role | Should -Be 'domain-controller'
        Clear-LabFact
        Get-LabFact -Name role | Should -Be 'workstation'
    }

    It 'an unknown fact name is an error' {
        { Get-LabFact -Name colour } | Should -Throw '*unknown fact colour*'
    }

    It 'Test-LabTool finds only commands that exist' {
        Test-LabTool -Name 'Get-Command' | Should -BeTrue
        Test-LabTool -Name 'lab-no-such-tool' | Should -BeFalse
    }

    It 'reading every fact calls nothing that changes the host' {
        Use-TestHost -ProductType 2
        Mock Set-ItemProperty { }
        Mock New-ItemProperty { }
        Mock Set-NetFirewallProfile { }
        Get-LabFact | Out-Null
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke New-ItemProperty -Times 0 -Exactly
        Should -Invoke Set-NetFirewallProfile -Times 0 -Exactly
    }
}
