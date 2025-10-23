function Install-Agents {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Install-Agents