function Install-PowerAutomate {
    param (
        [string]$DownloadURL = 'https://go.microsoft.com/fwlink/?linkid=2102613'
    )

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'PowerAutomate.exe' -Arguments '-Install -AcceptEULA -Silent'
}

<#
.SYNOPSIS
Installs LastPass using the specified LastPass installer URL.

.DESCRIPTION
The Install-LastPass function downloads and installs LastPass on the local machine using the LastPass installer URL provided as a parameter. By default, it uses the LastPassURL "https://download.cloud.lastpass.com/windows_installer/LastPassInstaller.msi".

.PARAMETER LastPassURL
Specifies the URL of the LastPass installer. If not provided, the default URL will be used.

.EXAMPLE
Install-LastPass -LastPassURL "https://example.com/lastpassinstaller.msi"
Downloads and installs LastPass using the specified LastPass installer URL.
#>
function Install-LastPass {
    param (
        [string]$LastPassURL = 'https://download.cloud.lastpass.com/windows_installer/LastPassInstaller.msi'
    )
    Invoke-DownloadAndStartProcess -DownloadURL $LastPassURL -FileName 'LastPassInstaller.msi' -Arguments 'ALLUSERS=1 ADDLOCAL=ExplorerExtension,ChromeExtension,FirefoxExtension,EdgeExtension NODISABLEIEPWMGR=1 NODISABLECHROMEPWMGR=1 /qn'
}


function Invoke-AgentInstall {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Write-Host "Installing Power Automate"
Install-PowerAutomate

Install-LastPass

Invoke-AgentInstall