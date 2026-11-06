#Requires -Version 5.1
# Labyrinth tab completion for PowerShell.
#
# install.ps1 copies this file into the Labyrinth module, next to the help
# topic (docs\Conventions.md section 3.3, The command). It holds no logic: it
# hands the words typed after the command to the hidden entry
# 'labyrinth.ps1 --complete WORD...', which only reads and prints one
# candidate per line (docs\Conventions.md section 3.1), and offers what comes
# back. The module has no commands; importing it registers the completer.

Set-StrictMode -Version Latest

# Get-LabCompletionScript NAME: the labyrinth.ps1 that the command NAME starts,
# or '' when NAME is not Labyrinth's launcher: another program of the same
# name is never run for a Tab. The launcher sits next to the script.
function Get-LabCompletionScript {
    param([string] $Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) { return '' }
    $runner = Join-Path (Split-Path -Parent $cmd.Source) 'labyrinth.ps1'
    if (Test-Path -LiteralPath $runner -PathType Leaf) { return $runner }
    return ''
}

# ConvertTo-LabCompletionArgument WORD: WORD as one argument of a command line.
function ConvertTo-LabCompletionArgument {
    param([string] $Word)
    return '"' + ($Word -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Get-LabCompletionLine AST CURSOR: the words typed after the command, up to
# the cursor. The last is the one being completed: '' after a space (the
# command's extent ends before a trailing space, so a cursor past it means one).
# PowerShell cannot hand a script a lone '-', so that last word goes as '--'
# (the long names), and a lone '-' before it is left out.
function Get-LabCompletionLine {
    param($CommandAst, [int] $Cursor)
    $text = $CommandAst.Extent.Text
    $upto = $Cursor - $CommandAst.Extent.StartOffset
    $space = $false
    if ($upto -gt $text.Length) { $space = $true }
    elseif ($upto -ge 0) { $text = $text.Substring(0, $upto) }
    if ($text -match '\s$') { $space = $true }
    $parts = @($text -split '\s+' | Where-Object { $_ -ne '' })
    $words = @()
    if ($parts.Count -gt 1) { $words = @($parts[1..($parts.Count - 1)] | ForEach-Object { $_.Trim([char] 34, [char] 39) }) }
    if ($space -or $words.Count -eq 0) { $words += '' }
    $out = @()
    for ($i = 0; $i -lt $words.Count; $i++) {
        if ($words[$i] -ne '-') { $out += $words[$i] }
        elseif ($i -eq $words.Count - 1) { $out += '--' }
    }
    return $out
}

# Get-LabCompletionCandidate SCRIPT WORD...: what 'labyrinth.ps1 --complete'
# prints for the words, one string per line. It is given a few seconds, and a
# failure gives nothing.
function Get-LabCompletionCandidate {
    param([string] $Script, [AllowEmptyString()] [string[]] $Word)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return @() }
    $quoted = @($Word | ForEach-Object { ConvertTo-LabCompletionArgument $_ })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        (ConvertTo-LabCompletionArgument $Script) + ' --complete ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(8000)) {
            $proc.Kill()
            return @()
        }
        return @($out.Result -split '\r?\n' | Where-Object { $_ -ne '' })
    } finally {
        $proc.Dispose()
    }
}

# Get-LabCompletionResult WORD AST CURSOR: the completions for a Labyrinth
# command line.
function Get-LabCompletionResult {
    param([string] $WordToComplete, $CommandAst, [int] $CursorPosition)
    $name = $CommandAst.GetCommandName()
    if ([string]::IsNullOrEmpty($name)) { return }
    $runner = Get-LabCompletionScript $name
    if ($runner -eq '') { return }
    $words = @(Get-LabCompletionLine $CommandAst $CursorPosition)
    $typed = $words[$words.Count - 1]
    foreach ($candidate in (Get-LabCompletionCandidate $runner $words)) {
        $text = $candidate
        # PowerShell may hand over only the last item of a comma list as the
        # word; the candidate then replaces just that item.
        if ($typed.Contains(',') -and -not $WordToComplete.Contains(',') -and $text.Contains(',')) {
            $text = $text.Substring($text.LastIndexOf(',') + 1)
        }
        New-Object System.Management.Automation.CompletionResult $text, $candidate, 'ParameterValue', $candidate
    }
}

Register-ArgumentCompleter -Native -CommandName 'laby', 'labyrinth' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-LabCompletionResult $wordToComplete $commandAst $cursorPosition
}

Export-ModuleMember -Function @()
