#Requires -Version 5.1
# core/Lab.ps1: loads the Labyrinth core library on Windows. The runner and
# every module entry point load it the same way (docs/Conventions.md section 3):
#
#   . (Join-Path $env:LAB_ROOT 'core\Lab.ps1')
#
# Loading it only defines functions; it changes nothing.

if (-not $env:LAB_ROOT) { throw 'LAB_ROOT is not set' }
. (Join-Path $env:LAB_ROOT 'core\config\Config.ps1')
. (Join-Path $env:LAB_ROOT 'core\log\Log.ps1')
. (Join-Path $env:LAB_ROOT 'core\manifest\Manifest.ps1')
. (Join-Path $env:LAB_ROOT 'core\safety\Safety.ps1')
. (Join-Path $env:LAB_ROOT 'core\safety\System.ps1')
. (Join-Path $env:LAB_ROOT 'core\probe\Probe.ps1')
