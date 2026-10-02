#Requires -Version 5.1
Invoke-WebRequest -Uri $u
Install-Module Pester
Get-LocalUser | Disable-LocalUser
Restart-Computer -Force
