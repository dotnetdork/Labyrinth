#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($v in "LAB_ROOT","LAB_CONFIG_DIR","LAB_STATE_DIR","LAB_LOG_DIR","LAB_BACKUP_DIR","LAB_RUN_ID","LAB_MODULE_ID","LAB_DRY_RUN") {
    Write-Output ("{0}={1}" -f $v, [Environment]::GetEnvironmentVariable($v))
}
exit 0
