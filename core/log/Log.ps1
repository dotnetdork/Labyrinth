#Requires -Version 5.1
# core/log/Log.ps1: the core logger (docs/Conventions.md section 6).
# Dot-sourced through core/Lab.ps1.
#
# Each call appends one JSON object on one line to
#   $env:LAB_LOG_DIR\<category>\<YYYYMMDD>.jsonl
# In plan mode (LAB_DRY_RUN=1) nothing is written, so a plan leaves no
# trace on the host. Warnings and errors are also printed to stderr.
# Never pass a secret to these functions, not even masked.

# Get-LabHostName: the short host name used in logs and the manifest. It
# picks the host's profile and group, so it comes from the system, not from
# $env:COMPUTERNAME, which the caller can set.
function Get-LabHostName { return ([Environment]::MachineName -split '\.')[0] }

# Get-LabUtcNow: the current UTC time in ISO 8601.
function Get-LabUtcNow { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

# ConvertTo-LabJsonString VALUE: VALUE as a JSON string literal, escaped
# exactly as the Linux core does it, so both write the same lines.
function ConvertTo-LabJsonString {
    param([AllowEmptyString()] [AllowNull()] [string] $Value)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    if ($null -ne $Value) {
        foreach ($c in $Value.ToCharArray()) {
            $code = [int]$c
            switch ($code) {
                34 { [void]$sb.Append('\"') }
                92 { [void]$sb.Append('\\') }
                10 { [void]$sb.Append('\n') }
                13 { [void]$sb.Append('\r') }
                9 { [void]$sb.Append('\t') }
                default {
                    if ($code -lt 32 -or $code -eq 127) { [void]$sb.Append(('\u{0:x4}' -f $code)) } else { [void]$sb.Append($c) }
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Add-LabTextLine PATH LINE: append one line as UTF-8 without a byte-order mark.
function Add-LabTextLine {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Line)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::AppendAllText($Path, $Line + "`n", (New-Object Text.UTF8Encoding $false))
}

# Write-LabLog -Level LEVEL -EventName EVENT -Message MSG [-Category CATEGORY]
function Write-LabLog {
    param(
        [ValidateSet('debug', 'info', 'warn', 'error')] [string] $Level = 'info',
        [Parameter(Mandatory)] [string] $EventName,
        [AllowEmptyString()] [string] $Message = '',
        [ValidateSet('run', 'auth', 'integrity', 'network', 'deception', 'report', 'health')] [string] $Category = 'run'
    )
    if ($EventName -cnotmatch '^[a-z0-9_]+$') { throw "Write-LabLog: event must be a short lower-case name: $EventName" }
    if ($Level -eq 'warn' -or $Level -eq 'error') {
        $who = if ($env:LAB_MODULE_ID) { $env:LAB_MODULE_ID } else { 'labyrinth' }
        [Console]::Error.WriteLine("[$who] ${Level}: $Message")
    }
    if ($env:LAB_DRY_RUN -ne '0' -or -not $env:LAB_LOG_DIR) { return }
    $fields = [ordered]@{
        ts = Get-LabUtcNow; host = Get-LabHostName; run = "$env:LAB_RUN_ID"; module = "$env:LAB_MODULE_ID"
        entry = "$env:LAB_ENTRY"; level = $Level; event = $EventName; msg = $Message
    }
    $line = '{' + (($fields.Keys | ForEach-Object { '"{0}":{1}' -f $_, (ConvertTo-LabJsonString $fields[$_]) }) -join ',') + '}'
    $file = Join-Path (Join-Path $env:LAB_LOG_DIR $Category) ([DateTime]::UtcNow.ToString('yyyyMMdd') + '.jsonl')
    Add-LabTextLine -Path $file -Line $line
}
