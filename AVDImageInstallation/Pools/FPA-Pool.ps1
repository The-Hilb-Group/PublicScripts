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

Install-ChocoPackages -Packages @('sql-server-management-studio')

Install-Agents