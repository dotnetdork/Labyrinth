#Requires -Version 5.1
# core/probe/Probe.ps1: scoring-style probes of the services in the run-time
# service list (design 01, section 9; design 13). Dot-sourced through
# core/Lab.ps1.
#
# A probe only checks that a service answers as expected; it never logs in.
# It uses .NET sockets, Resolve-DnsName and, for HTTPS, curl.exe when the
# host has it. When nothing can run a probe, the result is "unknown", which
# is never counted as a regression.
#
# Each probe gives one line: "<result> <detail>", result pass, fail or unknown.

# Invoke-LabTcpExchange: connect; optionally send text; return the first
# line (-FirstLine, then say QUIT) or up to 64 KiB of the reply. $null when
# the connection fails.
function Invoke-LabTcpExchange {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [int] $Timeout,
        [string] $Send = '',
        [switch] $FirstLine,
        [switch] $ConnectOnly
    )
    $client = New-Object Net.Sockets.TcpClient  # lab-guard: allow network -- probe of a listed scored service inside the event network
    try {
        if (-not $client.ConnectAsync($Target, $Port).Wait($Timeout * 1000)) { return $null }
        if ($ConnectOnly) { return '' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $Timeout * 1000
        $stream.WriteTimeout = $Timeout * 1000
        if ($Send -ne '') {
            $bytes = [Text.Encoding]::ASCII.GetBytes($Send)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        if ($FirstLine) {
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
            $line = $reader.ReadLine()
            $quit = [Text.Encoding]::ASCII.GetBytes("QUIT`r`n")
            try { $stream.Write($quit, 0, $quit.Length) } catch { $null = $_ }
            return $line
        }
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 8192
        try {
            while ($ms.Length -lt 65536) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n)
            }
        } catch { $null = $_ }
        return [Text.Encoding]::ASCII.GetString($ms.ToArray())
    } catch {
        return $null
    } finally {
        $client.Close()
    }
}

function Get-LabHttpResult {
    param([string] $Code, [string] $Body, [string] $Expect)
    if ($Code -notmatch '^[23][0-9][0-9]$') { return "fail status $Code" }
    if ($Expect -ne '-' -and -not $Body.Contains($Expect)) { return "fail status $Code but the expected text is missing" }
    return "pass status $Code"
}

# Invoke-LabProbe -Proto P -Target HOST -Port N -Expect E -Timeout S: probe one service.
function Invoke-LabProbe {
    param(
        [Parameter(Mandatory)] [string] $Proto,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [int] $Port,
        [Parameter(Mandatory)] [string] $Expect,
        [int] $Timeout = 5
    )
    $hostPart = if ($Target.Contains(':')) { "[$Target]" } else { $Target }
    switch ($Proto) {
        'http' {
            $out = Invoke-LabTcpExchange -Target $Target -Port $Port -Timeout $Timeout `
                -Send "GET / HTTP/1.0`r`nHost: $Target`r`nConnection: close`r`n`r`n"
            if (-not $out) { return 'fail no HTTP response' }
            if ($out -notmatch '^HTTP/[0-9.]+ ([0-9]{3})') { return 'fail not an HTTP response' }
            return Get-LabHttpResult $Matches[1] $out $Expect
        }
        'https' {
            $tool = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue  # lab-guard: allow network -- only checks whether curl.exe is installed
            if (-not $tool) { return 'unknown no tool on this host can probe https' }
            $saved = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $out = @(& $tool.Source -sS -k --max-time $Timeout -w '\n%{http_code}' "https://${hostPart}:$Port/" 2>$null)  # lab-guard: allow network -- probe of a listed scored service inside the event network
                $rc = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $saved
            }
            if ($rc -ne 0 -or $out.Count -eq 0) { return "fail the https client exited $rc" }
            return Get-LabHttpResult $out[-1] (($out | Select-Object -SkipLast 1) -join "`n") $Expect
        }
        'dns' {
            if ($Port -ne 53) { return 'unknown Windows can only query DNS on port 53' }
            if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { return 'unknown no Resolve-DnsName on this host' }
            $qname, $answer = $Expect -split '=', 2
            $answer = $answer.TrimEnd('.')
            $type = if ($answer.Contains(':')) { 'AAAA' } else { 'A' }
            try {
                $records = @(Resolve-DnsName -Name $qname -Server $Target -Type $type -DnsOnly -QuickTimeout -ErrorAction Stop)
            } catch {
                return "fail no answer from $Target"
            }
            foreach ($r in $records) {
                foreach ($prop in @('IPAddress', 'NameHost')) {
                    $p = $r.PSObject.Properties[$prop]
                    if ($p -and "$($p.Value)".TrimEnd('.') -eq $answer) { return "pass $qname answered $answer" }
                }
            }
            return "fail $qname did not answer $answer"
        }
        'tcp' {
            if ($Expect -eq '-') {
                if ($null -ne (Invoke-LabTcpExchange -Target $Target -Port $Port -Timeout $Timeout -ConnectOnly)) { return 'pass connected' }
                return 'fail no connection'
            }
        }
    }
    $prefix = @{ smtp = '220'; pop3 = '+OK'; ftp = '220'; tcp = '' }
    if (-not $prefix.ContainsKey($Proto)) { return "unknown unsupported protocol $Proto" }
    $banner = Invoke-LabTcpExchange -Target $Target -Port $Port -Timeout $Timeout -FirstLine
    if (-not $banner) { return 'fail no banner' }
    if ($prefix[$Proto] -ne '' -and -not $banner.StartsWith($prefix[$Proto])) { return 'fail unexpected banner' }
    if ($Expect -ne '-' -and -not $banner.Contains($Expect)) { return 'fail the banner lacks the expected text' }
    return 'pass banner received'
}

# Get-LabProbeResult [-Timeout S]: probe every service in the service list.
# Gives one line per service, "<name> <result> <detail>", or $null if there
# is no service list.
function Get-LabProbeResult {
    param([int] $Timeout = 5)
    $services = Read-LabServiceList
    if ($null -eq $services) { return $null }
    $lines = @(foreach ($s in $services) {
            '{0} {1}' -f $s.Name, (Invoke-LabProbe -Proto $s.Proto -Target $s.Target -Port $s.Port -Expect $s.Expect -Timeout $Timeout)
        })
    return , $lines
}

# Get-LabProbeRegression -Before LINES -After LINES: the services that passed
# before and fail after.
function Get-LabProbeRegression {
    param([AllowEmptyCollection()] [string[]] $Before = @(), [AllowEmptyCollection()] [string[]] $After = @())
    $was = @{}
    foreach ($l in $Before) {
        $f = $l -split ' ', 3
        if ($f.Count -ge 2) { $was[$f[0]] = $f[1] }
    }
    foreach ($l in $After) {
        $f = $l -split ' ', 3
        if ($f.Count -ge 2 -and $f[1] -eq 'fail' -and $was[$f[0]] -eq 'pass') { $f[0] }
    }
}
