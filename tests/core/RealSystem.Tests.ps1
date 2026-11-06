#Requires -Version 5.1
# Real-system tests for the Windows core: real scheduled tasks, run elevated.
# They run only where LAB_REALSYSTEM=1, which CI sets on its disposable
# runners; never on a developer's own machine (docs/Conventions.md section 9).

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeAll are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:HostExe = (Get-Process -Id $PID).Path

    # Wait-TestCondition SECONDS CONDITION: poll until CONDITION is true.
    function Wait-TestCondition {
        param([int] $Seconds, [scriptblock] $Condition)
        for ($i = 0; $i -lt $Seconds; $i += 5) {
            if (& $Condition) { return $true }
            Start-Sleep -Seconds 5
        }
        return [bool](& $Condition)
    }
}

Describe 'real system (Windows)' {
    It 'an armed revert timer fires, and a cancelled one does not' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $a = Join-Path $TestDrive 'fired-a'
        $b = Join-Path $TestDrive 'fired-b'
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        try {
            Register-LabRevertTimer -Seconds 5 -RunId '20261002T000000Z-aaaa' -Execute $cmd -Argument "/c echo x > `"$a`""
            Register-LabRevertTimer -Seconds 5 -RunId '20261002T000000Z-bbbb' -Execute $cmd -Argument "/c echo x > `"$b`""
            Test-LabRevertTimer -RunId '20261002T000000Z-aaaa' | Should -Be $true
            Unregister-LabRevertTimer -RunId '20261002T000000Z-bbbb'
            Wait-TestCondition 90 { Test-Path -LiteralPath $a } | Should -Be $true
            Start-Sleep -Seconds 5
            $b | Should -Not -Exist
        } finally {
            Unregister-LabRevertTimer -RunId '20261002T000000Z-aaaa'
        }
    }

    It 'an extended revert timer fires later, and the earlier one is gone' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $d = Join-Path $TestDrive 'fired-d'
        $run = '20261002T000000Z-dddd'
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        try {
            Register-LabRevertTimer -Seconds 5 -RunId $run -Execute $cmd -Argument "/c echo x > `"$d`""
            $left = Get-LabRevertTimerLeft -RunId $run
            $left | Should -BeGreaterThan 0
            $left | Should -BeLessOrEqual 5
            Register-LabRevertTimer -Seconds ($left + 120) -RunId $run -Execute $cmd -Argument "/c echo x > `"$d`""
            Test-LabRevertTimer -RunId $run | Should -Be $true
            Get-LabRevertTimerLeft -RunId $run | Should -BeGreaterThan 100
            # Past the earlier time, and still not fired.
            Start-Sleep -Seconds 20
            $d | Should -Not -Exist
            Wait-TestCondition 240 { Test-Path -LiteralPath $d } | Should -Be $true
        } finally {
            Unregister-LabRevertTimer -RunId $run
        }
    }

    It 'an apply that is not kept is rolled back by the timer' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $lab = Join-Path $TestDrive 'lab'
        $etc = Join-Path $TestDrive 'etc'
        $root = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Path (Join-Path $lab 'phases\observe\modules'), (Join-Path $lab 'profiles'), $etc -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'labyrinth.ps1') -Destination $lab
        Copy-Item -LiteralPath (Join-Path $script:Repo 'core') -Destination $lab -Recurse
        Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\fixtures\modules\toggle') -Destination (Join-Path $lab 'phases\observe\modules') -Recurse
        Set-Content -LiteralPath (Join-Path $lab 'profiles\test.profile') -Value 'observe.toggle' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'protected-accounts') -Value 'labadmin breakglass' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'hosts') -Value "$(([Environment]::MachineName -split '\.')[0]) ring0 test windows" -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'event.conf') -Value 'REVERT_MINUTES=1' -Encoding Ascii
        $toggle = Join-Path $lab 'toggle.conf'
        [IO.File]::WriteAllText($toggle, "setting=off`n")
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = @('labadmin', 'ring0', 'no') | & $script:HostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File (Join-Path $lab 'labyrinth.ps1') -r observe -Root $root -Config $etc 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        $text | Write-Verbose
        $code | Should -Be 0 -Because $text
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=on'
        # The run is rolled back once its last manifest entry is written.
        $rolledBack = {
            $manifest = Get-ChildItem -LiteralPath (Join-Path $root 'state\runs') -Recurse -Filter 'manifest.jsonl' | Get-Content
            ($manifest -join "`n") -match '"action":"run_rolled_back"'
        }
        Wait-TestCondition 150 $rolledBack | Should -Be $true
        (Get-Content -LiteralPath $toggle) | Should -Be 'setting=off'
    }
}
