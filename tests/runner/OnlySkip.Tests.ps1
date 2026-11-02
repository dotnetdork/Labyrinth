#Requires -Version 5.1
# Pester 5 tests for labyrinth.ps1 -Only and -Skip: preview or run chosen
# modules of a phase (docs\Conventions.md section 3.1, Partial runs).
# Mirrors only-skip.bats.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables set in BeforeEach are used in the It blocks, which the analyzer cannot see.')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'LabTestHelper.ps1')

    # Add-TestLockoutPhase T: a lockout phase with an inventory (a read-only
    # module, copied from the recorder) and a firewall that requires it
    # (copied from the dependent), and a profile that lists both.
    function Add-TestLockoutPhase {
        param($T)
        $m = Join-Path $T.Lab 'phases\lockout\modules'
        New-Item -ItemType Directory -Path $m -Force | Out-Null
        $src = Join-Path $script:Repo 'tests\fixtures\modules'
        Copy-Item -LiteralPath (Join-Path $src 'recorder') -Destination (Join-Path $m 'inventory') -Recurse
        Copy-Item -LiteralPath (Join-Path $src 'dependent') -Destination (Join-Path $m 'firewall') -Recurse
        Set-TestModuleLine (Join-Path $m 'inventory\module.yml') @{ id = 'lockout.inventory'; phase = 'lockout' }
        Set-TestModuleLine (Join-Path $m 'firewall\module.yml') @{
            id = 'lockout.firewall'; phase = 'lockout'; requires = '[lockout.inventory]' }
        Write-TestProfile $T @('lockout.inventory', 'lockout.firewall')
    }

    # Set-TestModuleLine PATH VALUES: replace the value of each named key in
    # a module.yml.
    function Set-TestModuleLine {
        param([string] $Path, [hashtable] $Values)
        $lines = Get-Content -LiteralPath $Path | ForEach-Object {
            $line = $_
            foreach ($k in $Values.Keys) { if ($line -match "^${k}:") { $line = "${k}: $($Values[$k])" } }
            $line
        }
        Set-Content -LiteralPath $Path -Value $lines -Encoding Ascii
    }

    # Invoke-TestLockout T ARGS [-Answers LINES]: -r lockout, typing LINES.
    function Invoke-TestLockout {
        param($T, [string[]] $Extra = @(), [string[]] $Answers = @('labadmin', 'ring1', 'no'))
        Invoke-TestLab $T (@('-r', 'lockout', '-Root', $T.Root, '-Config', $T.Etc) + $Extra) -Answers $Answers
    }

    # Test-NoRunMade T: nothing was written for a run.
    function Test-NoRunMade {
        param($T)
        $d = Join-Path $T.Root 'state\runs'
        return (-not (Test-Path -LiteralPath $d)) -or (@(Get-ChildItem -LiteralPath $d).Count -eq 0)
    }
}

Describe 'labyrinth.ps1 -Only and -Skip' {
    BeforeEach {
        $t = Initialize-TestLab
        $lab = $t.Lab
        $answers = @('labadmin', 'ring1', 'no')
        Write-TestHost $t 'ring1'
        Write-TestProfile $t @('observe.recorder', 'observe.toggle', 'observe.dependent')
    }

    It '-Only runs just the named module' {
        $r = Invoke-TestApply $t $answers @('-Only', 'observe.toggle')
        $r.Code | Should -Be 0
        Join-Path $lab 'toggle.conf' | Should -Exist
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
        Join-Path $t.Root 'state\recorder\marker' | Should -Not -Exist
        $r.Output | Should -Match 'Checking 1 module of profile test\.'
        $r.Output | Should -Match '(?m)^Partial run: only these observe modules \(-Only\):\r?\n  observe\.toggle\r?$'
        $r.Output | Should -Match 'Summary: 1 module: 1 OK\.'
        $r.Output | Should -Match 'Partial run: 1 of 3 modules of the phase \(-Only\)\.'
        $r.Output | Should -Not -Match 'Recording sample'
    }

    It '-Skip runs the rest' {
        $r = Invoke-TestApply $t $answers @('-Skip', 'observe.toggle')
        $r.Code | Should -Be 0
        Join-Path $lab 'toggle.conf' | Should -Not -Exist
        Get-Content -LiteralPath (Join-Path $t.Root 'state\recorder\marker') | Should -Contain 'dry=0'
        Join-Path $lab 'dependent.conf' | Should -Exist
        $r.Output | Should -Match 'Partial run: all observe modules but these \(-Skip\):\r?\n  observe\.toggle'
        $r.Output | Should -Match 'Partial run: 2 of 3 modules of the phase \(-Skip\)\.'
        $r.Output | Should -Not -Match 'Toggle setting sample'
    }

    It 'a preview takes -Only and -Skip too, and changes nothing' {
        $r = Invoke-TestPlan $t @('-Only', 'observe.toggle')
        $r.Code | Should -Be 10
        $r.Output | Should -Match 'Checking 1 module of profile test\.'
        $r.Output | Should -Match 'Toggle setting sample \(observe\.toggle\)'
        $r.Output | Should -Not -Match 'Recording sample'
        $r.Output | Should -Match 'Partial run: 1 of 3 modules of the phase \(-Only\)\.'
        $r.Output | Should -Match 'Nothing on this host was changed\.'
        Join-Path $lab 'toggle.conf' | Should -Not -Exist
        $r = Invoke-TestPlan $t @('-Skip', 'observe.toggle,observe.dependent')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Recording sample \(observe\.recorder\)'
        $r.Output | Should -Not -Match 'Toggle setting sample'
    }

    It 'an ID that is not a module of the phase in the profile is a usage error with a suggestion' {
        $r = Invoke-TestApply $t @() @('-Only', 'observe.togle')
        $r.Code | Should -Be 40
        $r.Output | Should -Match "-Only: 'observe\.togle' is not a module of the observe phase in profile test \(did you mean 'observe\.toggle'\?\)"
        Test-NoRunMade $t | Should -BeTrue
        $r = Invoke-TestPlan $t @('-Skip', 'observe.nothing')
        $r.Code | Should -Be 40
        $r.Output | Should -Match "-Skip: 'observe\.nothing' is not a module of the observe phase in profile test"
    }

    It 'a list that is not module IDs of the phase is a usage error' {
        $r = Invoke-TestLab $t @('observe', '-Only', 'toggle', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Output | Should -Match "-Only: not a module ID: 'toggle'"
        $r = Invoke-TestLab $t @('observe', '-Only', 'observe.toggle,', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'the list has an empty item'
        $r = Invoke-TestLab $t @('observe', '-Skip', 'lockout.inventory', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 40
        $r.Output | Should -Match "'lockout\.inventory' is not a module of the observe phase"
    }

    It '-Only and -Skip together, or with another action, are usage errors' {
        $r = Invoke-TestLab $t @('observe', '-Only', 'observe.toggle', '-Skip', 'observe.recorder')
        $r.Code | Should -Be 40
        $r.Output | Should -Match '-Only and -Skip cannot be used together'
        $r = Invoke-TestLab $t @('-k', '4f2a', '-Only', 'observe.toggle')
        $r.Code | Should -Be 40
        $r.Output | Should -Match '-Only is only for a preview or -r, not -k'
        $r = Invoke-TestLab $t @('-Skip', 'observe.toggle')
        $r.Code | Should -Be 40
        $r.Output | Should -Match 'no phase or action given'
    }

    It 'a skipped dependency blocks its dependent, and nothing is changed' {
        $r = Invoke-TestApply $t $answers @('-Only', 'observe.dependent')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'BLOCKED  Dependent sample \(observe\.dependent\)'
        $r.Output | Should -Match 'Problem:   needs observe\.recorder, which this run left out'
        $r.Output | Should -Match ('Fix:       .*-r observe -Only observe\.recorder,observe\.dependent -Root ' + [regex]::Escape($t.Root))
        $r.Output | Should -Match 'Summary: 1 module: 1 BLOCKED\.'
        $r.Output | Should -Match 'Nothing on this host was changed\.'
        $r.Output | Should -Match 'apply finished: exit 20 \(blocked\)'
        $r.Output | Should -Not -Match 'Type the group name'
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
        Test-NoRunMade $t | Should -BeTrue
    }

    It 'the fix for -Skip leaves the other skipped modules out' {
        $r = Invoke-TestApply $t @() @('-Skip', 'observe.recorder,observe.toggle')
        $r.Code | Should -Be 20
        $r.Output | Should -Match ('Fix:       .*-r observe -Skip observe\.toggle -Root ' + [regex]::Escape($t.Root))
        $r = Invoke-TestApply $t @() @('-Skip', 'observe.recorder')
        $r.Code | Should -Be 20
        $r.Output | Should -Match ('Fix:       .*-r observe -Root ' + [regex]::Escape($t.Root))
    }

    It 'a preview blocks the same way, and names the command without -r' {
        $r = Invoke-TestPlan $t @('-Only', 'observe.dependent')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'needs observe\.recorder, which this run left out'
        $r.Output | Should -Match 'Fix:       \S.* observe -Only observe\.recorder,observe\.dependent'
        $r.Output | Should -Not -Match 'Fix:       .* -r observe'
        $r.Output | Should -Match 'plan finished: exit 20 \(blocked\)'
    }

    It 'naming the dependency with the dependent runs both' {
        $r = Invoke-TestApply $t $answers @('-Only', 'observe.recorder,observe.dependent')
        $r.Code | Should -Be 0
        Join-Path $lab 'dependent.conf' | Should -Exist
        Get-Content -LiteralPath (Join-Path $t.Root 'state\recorder\marker') | Should -Contain 'dry=0'
        Join-Path $lab 'toggle.conf' | Should -Not -Exist
    }

    It 'only the modules of this run count: an earlier run of the dependency does not help' {
        $r = Invoke-TestApply $t $answers @('-Only', 'observe.recorder')
        $r.Code | Should -Be 0
        $r = Invoke-TestApply $t @('ring1', 'no') @('-Only', 'observe.dependent')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'needs observe\.recorder, which this run left out'
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
    }

    It 'the revert timer and the keep question work as in a full run, and the run is recorded as partial' {
        $r = Invoke-TestApply $t $answers @('-Only', 'observe.toggle')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Type keep to keep the changes'
        $r.Output | Should -Match 'The revert timer undoes this run'
        $r.Output | Should -Match 'Not kept\. To keep later:'
        $id = Get-TestRunId $r.Output
        Get-TestManifest $t $id | Should -Match '"action":"run_start".*"note":"phase observe, profile test, group ring1, partial -Only observe\.toggle"'
        $s = Invoke-TestLabCapture $t @('-Show', $id, '-Root', $t.Root, '-Config', $t.Etc)
        $s.Code | Should -Be 0
        $s.Out | Should -Match '(?m)^  Group:     ring1\r?\n  Partial:   -Only observe\.toggle\r?$'
        $s.Out | Should -Match '(?m)^  State:     armed: undo at '
        $u = Invoke-TestRunCommand $t 'rollback' $id
        $u.Code | Should -Be 0
        Join-Path $lab 'toggle.conf' | Should -Not -Exist
        $r = Invoke-TestApply $t @('ring1', 'keep') @('-Skip', 'observe.recorder,observe.dependent')
        $r.Code | Should -Be 0
        $r.Output | Should -Match 'Type keep to keep the changes'
        Get-TestManifest $t (Get-TestRunId $r.Output) | Should -Match '"action":"run_kept"'
        Join-Path $lab 'toggle.conf' | Should -Exist
    }

    It 'a full run is not partial: no header, no summary line, no note' {
        $r = Invoke-TestApply $t $answers
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'Partial run'
        $id = Get-TestRunId $r.Output
        Get-TestManifest $t $id | Should -Not -Match 'partial'
        $s = Invoke-TestLabCapture $t @('-Show', $id, '-Root', $t.Root, '-Config', $t.Etc)
        $s.Out | Should -Not -Match 'Partial:'
    }

    It 'a run that leaves out lockout.inventory is refused when the host has no dependency map' {
        Add-TestLockoutPhase $t
        $r = Invoke-TestLockout $t @('-Skip', 'lockout.inventory')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'BLOCKED  .*\(lockout\.inventory\)'
        $r.Output | Should -Match 'Problem:   this host has no dependency map yet, and the firewall would have'
        $r.Output | Should -Match 'nothing to keep open'
        $r.Output | Should -Match 'Fix:       run lockout\.inventory first, or leave it in'
        $r.Output | Should -Match 'Nothing on this host was changed\.'
        $r.Output | Should -Not -Match 'Type the group name'
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
        Test-NoRunMade $t | Should -BeTrue
        $r = Invoke-TestLockout $t @('-Only', 'lockout.firewall')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'this host has no dependency map yet'
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
        Test-NoRunMade $t | Should -BeTrue
    }

    It 'a run may leave out lockout.inventory when the host has a dependency map from an earlier run' {
        Add-TestLockoutPhase $t
        $dir = Join-Path $t.Root 'state\inventory'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'deps') -Value '10.0.0.5 tcp 53' -Encoding Ascii
        $r = Invoke-TestLockout $t @('-Skip', 'lockout.inventory')
        $r.Code | Should -Be 0
        $r.Output | Should -Not -Match 'BLOCKED'
        Join-Path $lab 'dependent.conf' | Should -Exist
        Join-Path $t.Root 'state\recorder\marker' | Should -Not -Exist
        $r.Output | Should -Match 'Partial run: 1 of 2 modules of the phase \(-Skip\)\.'
    }

    It 'a preview may always leave out lockout.inventory' {
        Add-TestLockoutPhase $t
        $r = Invoke-TestLab $t @('lockout', '-Skip', 'lockout.inventory', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 10
        $r.Output | Should -Not -Match 'BLOCKED'
        $r.Output | Should -Match 'Dependent sample \(lockout\.firewall\)'
    }

    It 'leaving out a module that is not the inventory is still refused when a map exists' {
        Add-TestLockoutPhase $t
        $dir = Join-Path $t.Root 'state\inventory'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'deps') -Value '' -Encoding Ascii
        $m = Join-Path $lab 'phases\lockout\modules'
        Set-TestModuleLine (Join-Path $m 'firewall\module.yml') @{ requires = '[lockout.inventory, lockout.other]' }
        Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\fixtures\modules\toggle') -Destination (Join-Path $m 'other') -Recurse
        Set-TestModuleLine (Join-Path $m 'other\module.yml') @{ id = 'lockout.other'; phase = 'lockout' }
        Write-TestProfile $t @('lockout.inventory', 'lockout.other', 'lockout.firewall')
        $r = Invoke-TestLockout $t @('-Skip', 'lockout.inventory,lockout.other')
        $r.Code | Should -Be 20
        $r.Output | Should -Match 'needs lockout\.other, which this run left out'
        $r.Output | Should -Match ('Fix:       .*-r lockout -Skip lockout\.inventory -Root ' + [regex]::Escape($t.Root))
        Join-Path $lab 'dependent.conf' | Should -Not -Exist
    }

    It 'help for -Only and -Skip prints a page and runs nothing' {
        $r = Invoke-TestLabCapture $t @('-Only', 'observe.toggle', '-h')
        $r.Code | Should -Be 0
        $r.Out | Should -Match '^Usage: .*labyrinth\.ps1 \[-r\] PHASE -Only LIST'
        $r = Invoke-TestLabCapture $t @('-h', 'skip')
        $r.Code | Should -Be 0
        $r.Out | Should -Match '^Usage: .*labyrinth\.ps1 \[-r\] PHASE -Skip LIST'
        $r = Invoke-TestLabCapture $t @('-r', 'observe', '-Skip', 'observe.toggle', '-Bogus', '-h', '-Root', $t.Root, '-Config', $t.Etc)
        $r.Code | Should -Be 0
        Test-NoRunMade $t | Should -BeTrue
    }
}
