#Requires -Version 5.1
# core/secret/Secret.ps1: new passwords, shown once on the operator's
# console for the offline record (design 04, section 2.3). Dot-sourced
# through core/Lab.ps1.
#
# A module's standard output goes to the run log and its standard input is
# not the operator's, so a password is written to the console directly and
# the answer is read from it. Nothing here logs, records or stores a password.

$script:LabConsoleSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LabConsole {
    [StructLayout(LayoutKind.Sequential)] struct Coord { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public short L; public short T; public short R; public short B; }
    [StructLayout(LayoutKind.Sequential)] struct BufferInfo { public Coord Size; public Coord Cursor; public ushort Attr; public Rect Window; public Coord Max; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WriteConsoleW(IntPtr h, string text, uint count, out uint written, IntPtr reserved);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ReadConsoleW(IntPtr h, StringBuilder buffer, uint count, out uint read, IntPtr control);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out BufferInfo info);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FillConsoleOutputCharacterW(IntPtr h, char c, uint count, Coord at, out uint written);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetConsoleCursorPosition(IntPtr h, Coord at);

    static readonly IntPtr Invalid = new IntPtr(-1);

    static IntPtr Open(string name) {
        // GENERIC_READ | GENERIC_WRITE, shared, OPEN_EXISTING
        return CreateFileW(name, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    }

    public static bool Available() {
        IntPtr o = Open("CONOUT$");
        IntPtr i = Open("CONIN$");
        uint mode;
        bool ok = o != Invalid && i != Invalid && GetConsoleMode(o, out mode) && GetConsoleMode(i, out mode);
        if (o != Invalid) { CloseHandle(o); }
        if (i != Invalid) { CloseHandle(i); }
        return ok;
    }

    public static bool Put(string text) {
        IntPtr o = Open("CONOUT$");
        if (o == Invalid) { return false; }
        try { uint n; return WriteConsoleW(o, text, (uint)text.Length, out n, IntPtr.Zero); }
        finally { CloseHandle(o); }
    }

    public static string ReadLine() {
        IntPtr i = Open("CONIN$");
        if (i == Invalid) { return null; }
        try {
            StringBuilder b = new StringBuilder(256);
            uint n;
            if (!ReadConsoleW(i, b, 256, out n, IntPtr.Zero) || n == 0) { return null; }
            return b.ToString(0, (int)n).TrimEnd('\r', '\n');
        }
        finally { CloseHandle(i); }
    }

    public static int Row() {
        IntPtr o = Open("CONOUT$");
        if (o == Invalid) { return -1; }
        try { BufferInfo b; return GetConsoleScreenBufferInfo(o, out b) ? b.Cursor.Y : -1; }
        finally { CloseHandle(o); }
    }

    public static int Width() {
        IntPtr o = Open("CONOUT$");
        if (o == Invalid) { return -1; }
        try { BufferInfo b; return GetConsoleScreenBufferInfo(o, out b) ? b.Size.X : -1; }
        finally { CloseHandle(o); }
    }

    public static void ClearFrom(int row) {
        IntPtr o = Open("CONOUT$");
        if (o == Invalid) { return; }
        try {
            BufferInfo b;
            if (row < 0 || !GetConsoleScreenBufferInfo(o, out b) || row > b.Cursor.Y) { return; }
            Coord at; at.X = 0; at.Y = (short)row;
            uint n;
            FillConsoleOutputCharacterW(o, ' ', (uint)((b.Cursor.Y - row + 1) * b.Size.X), at, out n);
            SetConsoleCursorPosition(o, at);
        }
        finally { CloseHandle(o); }
    }
}
'@

# Add the console type the first time it is needed. It is compiled from the
# source above by the .NET Framework that ships with Windows.
function Import-LabConsole {
    if (-not ('LabConsole' -as [type])) { Add-Type -TypeDefinition $script:LabConsoleSource }
}

# The console primitives. Runner tests replace them with doubles.

# Test-LabTerminal: is there a console to write to and read from?
function Test-LabTerminal {
    try { Import-LabConsole; return [LabConsole]::Available() } catch { return $false }
}

# Write-LabTerminal: write Text to the console, with no newline added.
function Write-LabTerminal {
    param([string] $Text)
    Import-LabConsole
    [void][LabConsole]::Put($Text)
}

# Read-LabTerminal: one line typed at the console, or $null when it is gone.
function Read-LabTerminal {
    Import-LabConsole
    return [LabConsole]::ReadLine()
}

# Clear-LabTerminal: blank what was just written to the console, Text (the
# shown block, then each prompt with the answer typed after it), and put the
# cursor where Text started. It counts back from where the cursor is now,
# not from a row saved before Text was written: when writing scrolls the
# window, the cursor's row number stays the same while the text moves up.
function Clear-LabTerminal {
    param([string] $Text)
    Import-LabConsole
    $end = [LabConsole]::Row()
    $width = [LabConsole]::Width()
    if ($end -lt 0 -or $width -lt 1) { return }
    [LabConsole]::ClearFrom((Get-LabClearRow -End $end -Lines (Get-LabTerminalRowCount -Text $Text -Width $width)))
}

# Get-LabTerminalRowCount -Text T -Width W: how many rows down the cursor moved
# while T was written from the start of a row on a console W columns wide,
# counting long lines that wrap. A line that exactly fills the width counts
# one row more than it may take, so a clear never falls short.
function Get-LabTerminalRowCount {
    param([string] $Text, [int] $Width)
    $parts = @(($Text -replace "`r", '') -split "`n")
    $rows = 0
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $wraps = 0
        if ($Width -gt 0) { $wraps = [Math]::Floor($parts[$i].Length / $Width) }
        $rows += $wraps
        # Every line but the last ended with a newline.
        if ($i -lt $parts.Count - 1) { $rows += 1 }
    }
    return [int] $rows
}

# Get-LabClearRow -End E -Lines N: the first row to clear when the cursor is
# on row E after moving N rows down: E - N, or row 0 when the text started
# above the top of the buffer.
function Get-LabClearRow {
    param([int] $End, [int] $Lines)
    return [int] [Math]::Max(0, $End - $Lines)
}

# Get-LabRandomSecret: a new password of Length characters (14 to 64; 20 by
# default) from the system's cryptographic random source. It uses letters,
# digits and -_.+=, leaves out characters easily mistaken when copied by hand
# (0 O 1 l I), starts with a letter, and has at least one of each kind.
function Get-LabRandomSecret {
    param([int] $Length = 20)
    if ($Length -lt 14 -or $Length -gt 64) { throw "secret: the length must be 14 to 64, not $Length" }
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789-_.+='
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($true) {
            $sb = New-Object System.Text.StringBuilder
            $bytes = New-Object byte[] 64
            while ($sb.Length -lt $Length) {
                $rng.GetBytes($bytes)
                foreach ($b in $bytes) {
                    # 248 is 4 x 62: a byte above it would favour the first characters.
                    if ($b -lt 248) { [void]$sb.Append($chars[$b % 62]) }
                    if ($sb.Length -eq $Length) { break }
                }
            }
            $pw = $sb.ToString()
            if ($pw -cmatch '^[A-Za-z]' -and $pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and
                $pw -match '[0-9]' -and $pw -match '[-_.+=]') {
                return $pw
            }
        }
    } finally {
        $rng.Dispose()
    }
}

# Test-LabSecretTerminal: can this run show a new password? Call it in apply
# before changing anything; without a console, change nothing and exit 20.
function Test-LabSecretTerminal { return (Test-LabTerminal) }

# Show-LabSecret: show Secret once on the console, wait until the operator
# types 'recorded', then clear it from the screen. Returns 0 once recorded,
# 20 when there is no console, and 1 when the console goes before the
# answer: the module must then roll back the change, because nobody
# recorded it.
function Show-LabSecret {
    param([string] $Label, [string] $Secret)
    if (-not (Test-LabTerminal)) {
        [Console]::Error.WriteLine('secret: no terminal to show the new password on')
        return 20
    }
    $shown = "`r`n  New password for $Label, shown once:`r`n`r`n      $Secret`r`n`r`n"
    Write-LabTerminal $shown
    while ($true) {
        $prompt = "  Type 'recorded' once it is in the offline record: "
        Write-LabTerminal $prompt
        $answer = Read-LabTerminal
        if ($null -eq $answer) {
            Write-LabTerminal "`r`n"
            return 1
        }
        # The console echoed the answer and the Enter that ended it.
        $shown += $prompt + $answer + "`r`n"
        if ($answer.Trim() -eq 'recorded') { break }
    }
    Clear-LabTerminal -Text $shown
    return 0
}
