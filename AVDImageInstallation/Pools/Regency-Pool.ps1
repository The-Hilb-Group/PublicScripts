<#
.SYNOPSIS
Installs a list of packages using Chocolatey.

.DESCRIPTION
This function takes an array of package names and installs each one using Chocolatey. It forces the installation and automatically confirms all prompts.

.PARAMETER Packages
An array of package names to install.

.EXAMPLE
Install-ChocoPackages -Packages @("git", "nodejs")

This will install git and nodejs using Chocolatey.

.NOTES
Chocolatey must be installed on the system for this function to work.
#>
function Install-ChocoPackages {
    param (
        [string[]]$Packages
    )

    foreach ($package in $Packages) {
        choco install $package -y -Force --ignore-checksums
    }
}

function Invoke-AgentInstall {
    $ScriptUrl = "https://raw.githubusercontent.com/mwandell-hilbgroup/HilbgroupAutomation/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Write-Host "Installing Chocolatey Packages"
Install-ChocoPackages -Packages @('trillian', 'roboform')

Invoke-AgentInstall