<#
.SYNOPSIS
ps2exe is a module to compile powershell scripts to executables.
.NOTES
Version: 1.0.20
Date: 2026.10.08
Fork Author: Andrew Afanasiev
Original author: Markus Scholtes
#>

# Load module manually for security reasons
. "$PSScriptRoot/ps2exe.ps1"
# Load the graphical front end (WinForms, PowerShell 5.1+, no dependencies)
. "$PSScriptRoot/Win-PS2EXE.ps1"

# Define aliases
Set-Alias ps2exe Invoke-ps2exe -Scope Global
Set-Alias ps2exe.ps1 Invoke-ps2exe -Scope Global
# GUI aliases launch the new script based front end instead of the legacy compiled exe
Set-Alias Win-PS2EXE Show-WinPS2EXE -Scope Global
Set-Alias Win-PS2EXE.exe Show-WinPS2EXE -Scope Global

# Export functions
Export-ModuleMember -Function @('Invoke-PS2EXE', 'Show-WinPS2EXE')
# Export aliases
Export-ModuleMember -Alias @('ps2exe', 'ps2exe.ps1', 'Win-PS2EXE', 'Win-PS2EXE.exe')
