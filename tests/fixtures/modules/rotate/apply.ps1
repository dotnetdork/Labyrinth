#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
# rotate.pw stands in for a password store: it holds a hash of the password.
if (-not (Test-LabSecretTerminal)) {
    Write-Output 'problem: no terminal to show the new password on, so nothing changed'
    exit 20
}
$f = Join-Path $env:LAB_ROOT 'rotate.pw'
Backup-LabFile -Path $f
$pw = Get-LabRandomSecret
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($pw)) | ForEach-Object { $_.ToString('x2') }) -join '' }
finally { $sha.Dispose() }
[IO.File]::WriteAllText($f, "$hash`n")
Write-LabLog -Level info -EventName rotated -Message 'new password for testuser'
if ((Show-LabSecret -Label 'testuser' -Secret $pw) -ne 0) {
    Restore-LabBackup
    Write-Output 'problem: the new password was not recorded, so the old one was put back'
    exit 40
}
Write-Output 'did: new password for testuser, shown once'
exit 0
