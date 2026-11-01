#Requires -Version 5.1
# Pester 5 tests for lockout.inventory on Windows (design 08, section 3.1).
# The functions that decide things take plain objects, so most tests feed
# them fixtures. The check.ps1 tests run it against the host it is on, and one
# test (LAB_REALSYSTEM=1, CI only) opens real sockets.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll and BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $script:Mod = Join-Path $script:Repo 'phases\lockout\modules\inventory'
    $script:HostExe = (Get-Process -Id $PID).Path
    $env:LAB_ROOT = $script:Repo
    . (Join-Path $script:Repo 'core\Lab.ps1')
    . (Join-Path $script:Mod 'Inventory.ps1')

    # Get-TestSocket FIELDS: a socket object as Get-InvCollectedSocket makes it.
    function Get-TestSocket {
        param([string] $Proto, [string] $State, [string] $Local, [int] $LocalPort, [string] $Remote, [int] $RemotePort, [int] $ProcessId)
        [pscustomobject]@{ Proto = $Proto; State = $State; LocalAddress = $Local; LocalPort = $LocalPort
            RemoteAddress = $Remote; RemotePort = $RemotePort; ProcessId = $ProcessId }
    }

    # Invoke-TestCheck DRYRUN: run the module's check.ps1 in a new process with
    # the environment the runner gives it; returns its output lines and exit code.
    function Invoke-TestCheck {
        param([string] $DryRun)
        $names = 'LAB_ROOT', 'LAB_CONFIG_DIR', 'LAB_STATE_DIR', 'LAB_LOG_DIR', 'LAB_BACKUP_DIR', 'LAB_RUN_ID', 'LAB_MODULE_ID', 'LAB_ENTRY', 'LAB_DRY_RUN'
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            $env:LAB_ROOT = $script:Repo
            $env:LAB_CONFIG_DIR = $script:Config
            $env:LAB_STATE_DIR = $script:State
            $env:LAB_LOG_DIR = Join-Path $script:Work 'logs'
            $env:LAB_BACKUP_DIR = Join-Path $script:Work 'backup'
            $env:LAB_RUN_ID = '20261101T000000Z-abcd'
            $env:LAB_MODULE_ID = 'lockout.inventory'
            $env:LAB_ENTRY = 'check'
            $env:LAB_DRY_RUN = $DryRun
            $out = @(& $script:HostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Mod 'check.ps1') 2>&1 | ForEach-Object { "$_" })
            return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
        } finally {
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
    }
}

Describe 'lockout.inventory' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config = Join-Path $script:Work 'config'
        $script:State = Join-Path $script:Work 'state'
        New-Item -ItemType Directory -Force -Path $script:Config | Out-Null
        $script:InvOut = New-Object Text.StringBuilder
        $script:InvCount = @{}
        $script:InvNote = @()
    }

    Describe 'the decisions, on fixtures' {
        BeforeEach {
            # nginx.exe (100) listens on 80 with a client; its worker (101) talks to a
            # database; ssh (300) holds a connection of its own; named (200) is DNS.
            $script:Sockets = @(
                (Get-TestSocket tcp LISTEN '0.0.0.0' 80 '0.0.0.0' 0 100)
                (Get-TestSocket tcp ESTAB '192.0.2.10' 80 '203.0.113.9' 51000 100)
                (Get-TestSocket tcp ESTAB '192.0.2.10' 44444 '198.51.100.5' 5432 101)
                (Get-TestSocket tcp ESTAB '192.0.2.10' 44445 '127.0.0.1' 3306 101)
                (Get-TestSocket tcp ESTAB '192.0.2.10' 44446 '::ffff:198.51.100.6' 25 101)
                (Get-TestSocket tcp ESTAB '192.0.2.10' 55555 '203.0.113.77' 22 300)
                (Get-TestSocket udp UNCONN '0.0.0.0' 53 '' 0 200)
                (Get-TestSocket udp ESTAB '192.0.2.10' 40000 '198.51.100.53' 53 200)
            )
            $script:Procs = @(
                [pscustomobject]@{ ProcessId = 4; ParentProcessId = 0; Name = 'System' }
                [pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; Name = 'nginx.exe' }
                [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'php cgi.exe' }
                [pscustomobject]@{ ProcessId = 200; ParentProcessId = 1; Name = 'dns.exe' }
                [pscustomobject]@{ ProcessId = 300; ParentProcessId = 1; Name = 'ssh.exe' }
                [pscustomobject]@{ ProcessId = 400; ParentProcessId = 101; Name = 'helper.exe' }
                [pscustomobject]@{ ProcessId = 500; ParentProcessId = 4; Name = 'w3wp.exe' }
                [pscustomobject]@{ ProcessId = 501; ParentProcessId = 500; Name = 'child.exe' }
            )
        }

        It 'descendants include the process itself and everything below it' {
            (@(Get-InvDescendant $script:Procs @(100)) -join ',') | Should -Be '100,101,400'
            (@(Get-InvDescendant $script:Procs @(300)) -join ',') | Should -Be '300'
        }

        It 'the service is the listener and its descendants' {
            (@(Get-InvServiceProcessId $script:Sockets 80 @('tcp') $script:Procs) -join ',') | Should -Be '100,101,400'
            @(Get-InvServiceProcessId $script:Sockets 8080 @('tcp') $script:Procs).Count | Should -Be 0
            # DNS answers on UDP and TCP; with TCP only the UDP listener is not it.
            (@(Get-InvServiceProcessId $script:Sockets 53 @('tcp', 'udp') $script:Procs) -join ',') | Should -Be '200'
            @(Get-InvServiceProcessId $script:Sockets 53 @('tcp') $script:Procs).Count | Should -Be 0
        }

        It 'a site served by the System process (id 4) means the w3wp.exe workers and their children' {
            $socks = @(Get-TestSocket tcp LISTEN '0.0.0.0' 8443 '0.0.0.0' 0 4)
            (@(Get-InvServiceProcessId $socks 8443 @('tcp') $script:Procs) -join ',') | Should -Be '500,501'
        }

        It 'outbound: a scored service connection is in, an inbound client is not' {
            $listen = @(53, 80)
            $o = @(Get-InvOutbound $script:Sockets @(100, 101, 400) $listen $script:Procs)
            (@($o | ForEach-Object { "$($_.Address) $($_.Proto) $($_.Port) $($_.Process)" }) -join '|') | Should -Be '198.51.100.5 tcp 5432 php_cgi.exe|198.51.100.6 tcp 25 php_cgi.exe'
            $o.Address | Should -Not -Contain '203.0.113.9'
            $o.Address | Should -Not -Contain '127.0.0.1'
            $o.Address | Should -Not -Contain '203.0.113.77'
        }

        It 'the map lines come from the scored services only' {
            $svc = @(
                [pscustomobject]@{ Name = 'web'; Proto = 'http'; Port = 80 }
                [pscustomobject]@{ Name = 'dns1'; Proto = 'dns'; Port = 53 }
                [pscustomobject]@{ Name = 'mail'; Proto = 'smtp'; Port = 25 }
            )
            $lines = @(Get-InvMapLine $svc $script:Sockets $script:Procs)
            ($lines -join '|') | Should -Be 'web 198.51.100.5 tcp 5432 php_cgi.exe|web 198.51.100.6 tcp 25 php_cgi.exe|dns1 198.51.100.53 udp 53 dns.exe'
        }

        It 'the map only grows: no duplicates, nothing removed, hand edits kept' {
            $f = Join-Path $script:Work 'deps'
            (Merge-InvMap $f @('web 198.51.100.5 tcp 5432 php', 'web 198.51.100.6 tcp 25 php')).Count | Should -Be 2
            (Get-Content -LiteralPath $f)[0] | Should -Match '^# service'
            Add-Content -LiteralPath $f -Value 'web 192.0.2.99 tcp 389 ldap'
            $added = @(Merge-InvMap $f @('web 198.51.100.5 tcp 5432 php-other', 'dns1 198.51.100.53 udp 53 dns'))
            ($added -join '|') | Should -Be 'dns1 198.51.100.53 udp 53 dns'
            $text = Get-Content -LiteralPath $f
            @($text | Where-Object { $_ -ne '' }).Count | Should -Be 6
            foreach ($want in 'web 198.51.100.5 tcp 5432 php', 'web 198.51.100.6 tcp 25 php', 'web 192.0.2.99 tcp 389 ldap', 'dns1 198.51.100.53 udp 53 dns') {
                $text | Should -Contain $want
            }
            $before = [IO.File]::ReadAllText($f)
            @(Merge-InvMap $f @()).Count | Should -Be 0
            @(Merge-InvMap $f @('dns1 198.51.100.53 udp 53 dns')).Count | Should -Be 0
            [IO.File]::ReadAllText($f) | Should -Be $before
        }

        It 'the map columns 2 to 4 are address, protocol and port, as in outbound-allow' {
            $f = Join-Path $script:Work 'deps'
            Merge-InvMap $f @('web 198.51.100.5 tcp 5432 php') | Out-Null
            $line = @(Get-Content -LiteralPath $f | Where-Object { $_ -notmatch '^#' })[0]
            ($line -split '\s+')[1..3] -join ' ' | Should -Be '198.51.100.5 tcp 5432'
        }
    }

    Describe 'what is recorded' {
        It 'a key is recorded by fingerprint, never the key itself' {
            Read-InvAuthorizedKey 'alice' 'C:\Users\alice\.ssh\authorized_keys' "# a comment`r`ncommand=`"x`",no-pty ssh-ed25519 dGVzdGtleWJsb2I= alice@example.test`r`n"
            $out = $script:InvOut.ToString()
            $out | Should -Match '"type":"ssh-ed25519"'
            $out | Should -Match '"fingerprint":"SHA256:IZO8V5UocbGYVwglouCMXzRBM68lWPPjxWEnkyZ1uNc"'
            $out | Should -Not -Match 'dGVzdGtleWJsb2I'
            $script:InvCount['key'] | Should -Be 1
        }

        It 'a program is kept without its arguments' {
            Get-InvExecutable '"C:\Program Files\App\app.exe" --token=SECRET' | Should -Be 'C:\Program Files\App\app.exe'
            Get-InvExecutable 'C:\Windows\System32\svchost.exe -k netsvcs -p' | Should -Be 'C:\Windows\System32\svchost.exe'
            Get-InvExecutable '' | Should -Be ''
        }

        It 'a record is one JSON line with numbers as numbers and quotes escaped' {
            Add-InvRecord 'listener' ([ordered]@{ proto = 'tcp'; port = '80'; pid = 'x'; name = 'a"b' })
            $script:InvOut.ToString() | Should -Be ("{`"kind`":`"listener`",`"proto`":`"tcp`",`"port`":80,`"pid`":null,`"name`":`"a\`"b`"}`n")
        }
    }

    Describe 'check.ps1 on this host' {
        It 'a preview prints what it found and writes nothing' {
            Set-Content -LiteralPath (Join-Path $script:Config 'services') -Value 'web http www.example.test 80 Welcome'
            $r = Invoke-TestCheck '1'
            $r.Code | Should -Be 0
            ($r.Output -join "`n") | Should -Match 'found: \d+ user'
            ($r.Output -join "`n") | Should -Not -Match 'did:'
            $script:State | Should -Not -Exist
        }

        It 'a run writes the inventory and the map, and a second run never shrinks the map' {
            Set-Content -LiteralPath (Join-Path $script:Config 'services') -Value 'web http www.example.test 80 Welcome'
            $r = Invoke-TestCheck '0'
            $r.Code | Should -Be 0
            $dir = Join-Path $script:State 'inventory'
            @(Get-ChildItem -LiteralPath $dir -Filter *.jsonl).Count | Should -Be 1
            $deps = Join-Path $dir 'deps'
            $deps | Should -Exist
            foreach ($l in Get-Content -LiteralPath (Get-ChildItem -LiteralPath $dir -Filter *.jsonl)[0].FullName) {
                $l | Should -Match '^\{"kind":"[a-z]+".*\}$'
            }
            Add-Content -LiteralPath $deps -Value 'web 192.0.2.99 tcp 389 ldap'
            $before = [IO.File]::ReadAllText($deps)
            Start-Sleep -Seconds 1
            (Invoke-TestCheck '0').Code | Should -Be 0
            @(Get-ChildItem -LiteralPath $dir -Filter *.jsonl).Count | Should -Be 2
            [IO.File]::ReadAllText($deps).StartsWith($before) | Should -BeTrue
        }

        It 'with no services file the inventory is still taken, with a note and no map' {
            $r = Invoke-TestCheck '0'
            $r.Code | Should -Be 0
            ($r.Output -join "`n") | Should -Match 'found: note: there is no services file, so there is no dependency map'
            @(Get-ChildItem -LiteralPath (Join-Path $script:State 'inventory') -Filter *.jsonl).Count | Should -Be 1
            (Join-Path $script:State 'inventory\deps') | Should -Not -Exist
        }

        It 'a run changes no startup entry in the registry, and records no secret' {
            $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            $snap = { foreach ($k in $keys) { if (Test-Path $k) { (Get-ItemProperty $k | ConvertTo-Json -Compress) } } }
            $before = @(& $snap)
            Set-Content -LiteralPath (Join-Path $script:Config 'services') -Value 'web http www.example.test 80 Welcome'
            (Invoke-TestCheck '0').Code | Should -Be 0
            @(& $snap) | Should -Be $before
            foreach ($f in Get-ChildItem -LiteralPath $script:State -Recurse -File) {
                [IO.File]::ReadAllText($f.FullName) | Should -Not -Match 'PRIVATE KEY|AAAA[A-Za-z0-9+/]{40}'
            }
        }

        It 'the module code has no command that changes the host' {
            foreach ($name in 'Inventory.ps1', 'check.ps1', 'plan.ps1') {
                $code = (Get-Content -LiteralPath (Join-Path $script:Mod $name) | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
                $code | Should -Not -Match '\b(Set-ItemProperty|New-ItemProperty|Remove-Item|Remove-ItemProperty|Stop-Service|Start-Service|Set-Service|Stop-Process|Disable-|Enable-|Set-NetFirewall|New-NetFirewall|Remove-NetFirewall|Set-LocalUser|New-LocalUser|Remove-LocalUser|Register-ScheduledTask|Unregister-ScheduledTask|Set-ExecutionPolicy|Add-LocalGroupMember|Remove-LocalGroupMember|netsh|sc\.exe|reg\.exe|icacls|takeown)\b'
            }
        }
    }

    Describe 'the profiles' {
        It 'lockout.inventory is the first module of every shipped profile but the appliance' {
            $yml = Get-Content -LiteralPath (Join-Path $script:Mod 'module.yml')
            $yml | Should -Contain 'risk: read-only'
            foreach ($p in Get-ChildItem -LiteralPath (Join-Path $script:Repo 'profiles') -Filter *.profile) {
                $first = @(Get-Content -LiteralPath $p.FullName | ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
                        Where-Object { $_ -match '^(lockout|observe|deceive|sustain)\.' })[0]
                if ($p.BaseName -eq 'appliance') { $first | Should -Not -Be 'lockout.inventory' } else { $first | Should -Be 'lockout.inventory' }
            }
        }
    }

    Describe 'real system (Windows)' {
        It 'a scored service real outbound connection is mapped, a loopback client is not' -Skip:($env:LAB_REALSYSTEM -ne '1') {
            $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })[0].IPAddress
            if (-not $ip) { Set-ItResult -Skipped -Because 'this host has no non-loopback address'; return }
            Set-Content -LiteralPath (Join-Path $script:Config 'services') -Value 'svc http host.example.test 38101 Welcome'
            $any = [Net.IPAddress]::Any
            $srv = New-Object Net.Sockets.TcpListener $any, 38101
            $dep = New-Object Net.Sockets.TcpListener $any, 38102
            $out = $null
            $loop = $null
            try {
                $srv.Start(); $dep.Start()
                $out = New-Object Net.Sockets.TcpClient
                $out.Connect($ip, 38102)
                $loop = New-Object Net.Sockets.TcpClient
                $loop.Connect('127.0.0.1', 38101)
                $r = Invoke-TestCheck '0'
                $r.Code | Should -Be 0
                $deps = Get-Content -LiteralPath (Join-Path $script:State 'inventory\deps')
                ($deps | Where-Object { $_ -match "^svc $([regex]::Escape($ip)) tcp 38102 " }).Count | Should -BeGreaterThan 0
                ($deps | Where-Object { $_ -match ' 127\.' }).Count | Should -Be 0
                ($deps | Where-Object { $_ -match ' tcp 38101 ' }).Count | Should -Be 0
            } finally {
                if ($out) { $out.Close() }
                if ($loop) { $loop.Close() }
                $srv.Stop(); $dep.Stop()
            }
        }
    }
}
