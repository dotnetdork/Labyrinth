#Requires -Version 5.1
# Test fixture: the recording pass (design 00, section 4). In a preview
# (LAB_DRY_RUN=1) it writes nothing; in a run (0) it writes a marker under the
# state folder, noting the toggle.conf it saw, or fails when FAIL_RECORD exists.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:LAB_DRY_RUN -ne '0') {
    if (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'CHECK_TEN')) { Write-Output 'will do: write the marker'; exit 10 }
    Write-Output 'found: would write the marker'
    exit 0
}
if (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'FAIL_RECORD')) {
    Write-Output 'problem: the marker could not be written'
    exit 40
}
$dir = Join-Path $env:LAB_STATE_DIR 'recorder'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$seen = 'none'
$toggle = Join-Path $env:LAB_ROOT 'toggle.conf'
if (Test-Path -LiteralPath $toggle -PathType Leaf) { $seen = (Get-Content -LiteralPath $toggle) -join '' }
[IO.File]::WriteAllText((Join-Path $dir 'marker'), "dry=$($env:LAB_DRY_RUN)`ntoggle=$seen`n")
Write-Output 'found: wrote the marker'
exit 0
