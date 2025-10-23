$ProgressPreference = 'SilentlyContinue'

function Get-TempFilePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    $TempDirectory = [System.IO.Path]::GetTempPath()
    return (Join-Path -Path $TempDirectory -ChildPath $FileName)
}

function Invoke-DownloadAndStartProcess {
    param (
        [string]$DownloadURL,
        [string]$FileName,
        [string]$Arguments
    )
    $ProgressPreference = 'SilentlyContinue'
    $TempFilePath = Get-TempFilePath -FileName $FileName
    Invoke-WebRequest -Uri $DownloadURL -OutFile $TempFilePath
    $ProgressPreference = 'Continue'
    Start-Process $TempFilePath -ArgumentList $Arguments -Wait
}

function Install-Zulu {
    $ZuluUrl17 = 'https://cdn.azul.com/zulu/bin/zulu17.62.17-ca-jdk17.0.17-win_x64.msi'
    $Zulu8 = 'https://cdn.azul.com/zulu/bin/zulu8.90.0.19-ca-jdk8.0.472-win_x64.msi'


    Invoke-DownloadAndStartProcess -DownloadURL $ZuluUrl17 -FileName "zulu17.msi" -Arguments "/qn"
    Invoke-DownloadAndStartProcess -DownloadURL $Zulu8 -FileName "zulu8.msi" -Arguments "/qn"
}

function Install-OxygenDeveloper {
    $OxygenUrl = "https://mirror.oxygenxml.com/InstData/Developer/Windows64/VM/oxygenDeveloper-64bit-openjdk.exe"

    Invoke-DownloadAndStartProcess -DownloadURL $OxygenUrl -FileName "OxygenDeveloper.exe" -Arguments "/qn"
}

function Add-ApplicationDesktopShortcut {
    if (-not (Test-Path -Path "C:\hilb")) {
        New-Item -Path "C:\Hilb" -ItemType Directory
    }
    $EXEUrl = "https://github.com/The-Hilb-Group/PublicScripts/raw/refs/heads/main/AVDImageInstallation/Pools/Install-PwC-Apps.exe"
    $DestinationFile = "C:\hilb\Install-PwC-Apps.exe"

    Invoke-WebRequest -Uri $EXEUrl -OutFile $DestinationFile
    $ShortcutPath = "$env:PUBLIC\Desktop\Install PwC Applications.lnk"
    $TargetPath = $DestinationFile
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $TargetPath
    $Shortcut.Save()
}

function Install-Agents {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}


Install-Zulu

Add-ApplicationDesktopShortcut

Install-Agents