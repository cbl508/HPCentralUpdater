$ErrorActionPreference = "Stop"

Write-Host "Checking for PS2EXE module..."
if (-not (Get-Module -ListAvailable PS2EXE)) {
    Write-Host "Installing PS2EXE..."
    Install-Module PS2EXE -Scope CurrentUser -Force -AcceptLicense
}

Write-Host "Compiling securepaq-gui.ps1 to securepaq-web-server.exe..."
Invoke-PS2EXE -InputFile ".\securepaq-gui.ps1" -OutputFile ".\securepaq-web-server.exe" -noConsole -RequireAdmin

Write-Host "Finding Inno Setup Compiler..."
$iscc = "C:\Program Files (x86)\Inno Setup 6\iscc.exe"
if (-not (Test-Path $iscc)) {
    $iscc = "C:\Program Files\Inno Setup 6\iscc.exe"
}

if (Test-Path $iscc) {
    Write-Host "Compiling installer.iss..."
    & $iscc "..\HP.UpdateManager.Gui\installer.iss"
    Write-Host "Build complete. Check HP.UpdateManager.Gui\Output for the installer."
}
else {
    Write-Host "Inno Setup Compiler not found! Please install Inno Setup 6."
}
