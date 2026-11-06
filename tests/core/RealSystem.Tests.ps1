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

    It 'the warning is a scheduled task, and keeping the run removes it with the timer' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $run = '20261002T000000Z-eeee'
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        try {
            Register-LabRevertTimer -Seconds 300 -RunId $run -Execute $cmd -Argument '/c rem'
            Register-LabRevertWarning -Seconds 300 -RunId $run -Execute $cmd -Argument '/c rem'
            Get-ScheduledTask -TaskName "lab-warn-$run-1" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Get-ScheduledTask -TaskName "lab-revert-$run-1" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            # An extension moves both: the new pair is there and the earlier one is gone.
            Register-LabRevertTimer -Seconds 400 -RunId $run -Execute $cmd -Argument '/c rem'
            Register-LabRevertWarning -Seconds 400 -RunId $run -Execute $cmd -Argument '/c rem'
            Get-ScheduledTask -TaskName "lab-warn-$run-1" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-ScheduledTask -TaskName "lab-warn-$run-2" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            Unregister-LabRevertTimer -RunId $run
            Get-ScheduledTask -TaskName "lab-warn-$run-2" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-ScheduledTask -TaskName "lab-revert-$run-2" -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Join-Path (Get-LabRunDir $run) 'warn' | Should -Not -Exist
        } finally {
            Unregister-LabRevertTimer -RunId $run
        }
    }

    It 'the warning task fires before the revert timer does' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $run = '20261002T000000Z-ffff'
        $warned = Join-Path $TestDrive 'warned'
        $fired = Join-Path $TestDrive 'fired-undo'
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        try {
            Register-LabRevertTimer -Seconds 130 -RunId $run -Execute $cmd -Argument "/c echo x > `"$fired`""
            Register-LabRevertWarning -Seconds 130 -RunId $run -Execute $cmd -Argument "/c echo x > `"$warned`""
            Wait-TestCondition 240 { (Test-Path -LiteralPath $warned) -and (Test-Path -LiteralPath $fired) } | Should -Be $true
            (Get-Item -LiteralPath $warned).LastWriteTimeUtc | Should -BeLessThan (Get-Item -LiteralPath $fired).LastWriteTimeUtc
        } finally {
            Unregister-LabRevertTimer -RunId $run
        }
    }

    It 'an apply that is not kept is warned before the timer rolls it back' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $lab = Join-Path $TestDrive 'lab-warn'
        $etc = Join-Path $TestDrive 'etc-warn'
        $root = Join-Path $TestDrive 'root-warn'
        New-Item -ItemType Directory -Path (Join-Path $lab 'phases\observe\modules'), (Join-Path $lab 'profiles'), $etc -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo 'labyrinth.ps1') -Destination $lab
        Copy-Item -LiteralPath (Join-Path $script:Repo 'core') -Destination $lab -Recurse
        Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\fixtures\modules\toggle') -Destination (Join-Path $lab 'phases\observe\modules') -Recurse
        Set-Content -LiteralPath (Join-Path $lab 'profiles\test.profile') -Value 'observe.toggle' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'protected-accounts') -Value 'labadmin breakglass' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'hosts') -Value "$(([Environment]::MachineName -split '\.')[0]) ring0 test windows" -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $etc 'event.conf') -Value 'REVERT_MINUTES=1' -Encoding Ascii
        [IO.File]::WriteAllText((Join-Path $lab 'toggle.conf'), "setting=off`n")
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
        $code | Should -Be 0 -Because $text
        $rolledBack = {
            $manifest = Get-ChildItem -LiteralPath (Join-Path $root 'state\runs') -Recurse -Filter 'manifest.jsonl' | Get-Content
            ($manifest -join "`n") -match '"action":"run_rolled_back"'
        }
        Wait-TestCondition 150 $rolledBack | Should -Be $true
        # The warning task ran the hidden entry before the undo, and both tasks are gone.
        $log = Get-ChildItem -LiteralPath (Join-Path $root 'state\runs') -Recurse -Filter 'output.log' | Get-Content
        $warnAt = [array]::IndexOf(@($log), @($log | Where-Object { $_ -match ': warn run ' })[0])
        $undoAt = [array]::IndexOf(@($log), @($log | Where-Object { $_ -match ': undo run ' })[0])
        $warnAt | Should -BeGreaterOrEqual 0
        $undoAt | Should -BeGreaterThan $warnAt
        $runId = (Get-ChildItem -LiteralPath (Join-Path $root 'state\runs') -Directory | Select-Object -First 1).Name
        @(Get-ScheduledTask -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "lab-*-$runId-*" }) | Should -BeNullOrEmpty
    }

    It 'the timer-ready check passes on this runner and arms nothing' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $before = @(Get-ScheduledTask -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
        Test-LabTimerReady | Should -BeExactly ''
        $after = @(Get-ScheduledTask -TaskPath '\Labyrinth\' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
        $after.Count | Should -Be $before.Count
    }

    It 'the clock-sync check answers with a defined value, quickly' -Skip:($env:LAB_REALSYSTEM -ne '1') {
        $env:LAB_ROOT = $script:Repo
        $env:LAB_STATE_DIR = Join-Path $TestDrive 'state'
        . (Join-Path $script:Repo 'core\Lab.ps1')
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $answer = Get-LabClockSync
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
        @('', 'Windows Time', 'unknown') | Should -Contain $answer
    }
}
