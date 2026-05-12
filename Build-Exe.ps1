#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles Deploy-IntuneBaselines-GUI.ps1 into a standalone .exe using ps2exe.

.DESCRIPTION
    Installs ps2exe from the PowerShell Gallery if not already present, then
    compiles the GUI script into a self-contained Windows executable that
    does not require PowerShell to be manually launched.

.EXAMPLE
    .\Build-Exe.ps1
#>

$ErrorActionPreference = 'Stop'
$scriptDir  = $PSScriptRoot
$sourceFile = Join-Path $scriptDir 'Deploy-IntuneBaselines-GUI.ps1'
$outputExe  = Join-Path $scriptDir 'IntuneBaselinesDeployer.exe'

if (-not (Test-Path $sourceFile)) {
    throw "Source script not found: $sourceFile"
}

# Install ps2exe if needed
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing ps2exe from PSGallery...' -ForegroundColor Cyan
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}

Import-Module ps2exe -ErrorAction Stop

Write-Host 'Compiling GUI script to executable...' -ForegroundColor Cyan

Invoke-ps2exe `
    -InputFile   $sourceFile `
    -OutputFile  $outputExe `
    -NoConsole `
    -Title       'Intune Baselines Deployer' `
    -Description 'Deploy Intune Configuration Profiles from local JSON baselines' `
    -Company     'IntuneBaselines' `
    -Version     '1.0.0' `
    -RequireAdmin

if (Test-Path $outputExe) {
    Write-Host ''
    Write-Host "Build complete: $outputExe" -ForegroundColor Green
    Write-Host 'You can distribute and run this .exe on any Windows machine.' -ForegroundColor Gray
}
else {
    Write-Host 'Build failed — output file not found.' -ForegroundColor Red
}
