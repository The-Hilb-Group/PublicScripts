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


function Install-Agents {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Install-SMSS

Install-Agents