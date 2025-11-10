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

function Install-SMSS {
    $Url = "https://aka.ms/ssms/21/release/vs_SSMS.exe"
    $Arguments = "--quiet --norestart"

    Invoke-DownloadAndStartProcess -DownloadURL $Url -FileName "vs_SSMS.exe" -Arguments $Arguments
}

function Install-DataGrip {
    $DownloadUrl = "https://download.jetbrains.com/datagrip/datagrip-2025.2.4.win.zip"

    $ZipFileName = "datagrip-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
    $TempFilePath = Get-TempFilePath -FileName $ZipFileName
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFilePath

    $JetBrainsPath = "C:\Program Files\JetBrains"
    if (-not (Test-Path $JetBrainsPath)) {
        New-Item -Path $JetBrainsPath -ItemType Directory -Force | Out-Null
    }

    $InstallPath = Join-Path -Path $JetBrainsPath -ChildPath "DataGrip"

    if (-not (Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }

    Expand-Archive -Path $TempFilePath -DestinationPath $InstallPath -Force

    $ExePath = Join-Path -Path $InstallPath -ChildPath "bin\datagrip64.exe"

    $WshShell = New-Object -ComObject WScript.Shell

    # Create Desktop shortcut
    $AllUsersDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
    $DesktopShortcut = Join-Path -Path $AllUsersDesktop -ChildPath "DataGrip.lnk"
    $Shortcut = $WshShell.CreateShortcut($DesktopShortcut)
    $Shortcut.TargetPath = $ExePath
    $Shortcut.WorkingDirectory = Join-Path -Path $InstallPath -ChildPath "bin"
    $Shortcut.Description = "JetBrains DataGrip"
    $Shortcut.Save()

    # Create Start Menu shortcut (All Users)
    $AllUsersStartMenu = [Environment]::GetFolderPath("CommonPrograms")
    $StartMenuPath = Join-Path -Path $AllUsersStartMenu -ChildPath "JetBrains"
    if (-not (Test-Path $StartMenuPath)) {
        New-Item -Path $StartMenuPath -ItemType Directory -Force | Out-Null
    }
    $StartMenuShortcut = Join-Path -Path $StartMenuPath -ChildPath "DataGrip.lnk"
    $Shortcut = $WshShell.CreateShortcut($StartMenuShortcut)
    $Shortcut.TargetPath = $ExePath
    $Shortcut.WorkingDirectory = Join-Path -Path $InstallPath -ChildPath "bin"
    $Shortcut.Description = "JetBrains DataGrip"
    $Shortcut.Save()

    Remove-Item -Path $TempFilePath -Force -ErrorAction SilentlyContinue
}

function Install-ChocoPackages {
    param (
        [string[]]$Packages
    )

    foreach ($package in $Packages) {
        choco install $package -y -Force --ignore-checksums
    }
}

function Install-Agents {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Install-DataGrip

Install-ChocoPackages -Packages @('r.studio')

Install-Agents