@echo off
set "tmp_script=%TEMP%\Install-IRAdobePlugin.ps1"
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/UtilityScripts/Install-IRAdobePlugin.ps1' -OutFile '%tmp_script%'"
powershell -ExecutionPolicy Bypass -File "%tmp_script%"
del "%tmp_script%"
pause
