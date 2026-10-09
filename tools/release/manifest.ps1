#Requires -Version 5.1
<#
.SYNOPSIS
    Write release.sha256, the release list, into a copy of Labyrinth and
    print its SHA-256 (design 07, section 5).

.DESCRIPTION
    Run it on the copy that will be deployed, after it is unpacked and
    before it is copied to the hosts, and keep the SHA-256 it prints in
    the team's offline record. Copy the folder to the hosts byte for byte:
    changing line ends, as a git checkout may, changes the hashes.

.EXAMPLE
    .\tools\release\manifest.ps1 C:\release\labyrinth
#>
param([string] $Folder = (Join-Path $PSScriptRoot '..\..'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\core\safety\Release.ps1')
$root = (Get-Item -LiteralPath $Folder -Force).FullName.TrimEnd('\')
$sum = Write-LabRelease -Root $root
$check = Test-LabRelease -Root $root
if ($check.Status -ne 'ok') {
    [Console]::Error.WriteLine("manifest.ps1: the new list does not check: $($check.Problem)")
    exit 1
}
Write-Output "Wrote $(Join-Path $root 'release.sha256')"
Write-Output "Release: $sum"
