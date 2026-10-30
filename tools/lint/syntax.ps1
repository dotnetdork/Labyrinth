#Requires -Version 5.1
<#
.SYNOPSIS
    Check every PowerShell file in the repository for syntax errors without
    running any of them.

.DESCRIPTION
    Each .ps1 and .psm1 file is only parsed, never run, so this is safe on a
    machine where the runners and tests must not run. Exits 1 if any file has
    a syntax error, else 0. For bash, use `bash -n <file>` the same way.

.EXAMPLE
    pwsh -NoProfile -File tools/lint/syntax.ps1
#>
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failed = 0
Get-ChildItem -Path $repo -Recurse -File -Include '*.ps1', '*.psm1' |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|vendor)[\\/]' } |
    ForEach-Object {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        foreach ($e in $errors) {
            $failed++
            Write-Output ('{0}:{1}: {2}' -f $_.FullName.Substring($repo.Length + 1), $e.Extent.StartLineNumber, $e.Message)
        }
    }
if ($failed -gt 0) { exit 1 }
Write-Output 'No syntax errors.'
