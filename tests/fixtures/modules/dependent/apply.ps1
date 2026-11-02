#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
$f = Join-Path $env:LAB_ROOT 'dependent.conf'
Backup-LabFile -Path $f
[IO.File]::WriteAllText($f, "setting=on`n")
if (Test-Path -LiteralPath (Join-Path $env:LAB_ROOT 'FAIL_APPLY')) { Write-Output 'dependent: apply forced to fail'; exit 40 }
Write-LabLog -Level info -EventName toggled -Message 'setting=on'
Write-Output 'dependent: setting=on'
exit 0
