<#
.SYNOPSIS
A script to install various software components including Adobe Acrobat, AMS360, .NET Framework 4.8, Microsoft Edge WebView2 Runtime, and WorkSmart.

.DESCRIPTION
This script contains functions to install various software components. Each function downloads the necessary files from the provided URLs and then installs the software. Some functions also check if the software is already installed and skip the installation if it is.

The script contains the following functions:
- Install-AdobeAcrobat: Installs Adobe Acrobat.
- Install-AMS360: Installs AMS360.
- Install-Net48: Installs .NET Framework 4.8.
- Install-Web2View: Installs Microsoft Edge WebView2 Runtime.
- Install-WorkSmart: Installs WorkSmart.

.EXAMPLE
To use the functions in the script, you can dot-source the script and then call the functions. For example:

. .\script.ps1
Install-AdobeAcrobat
Install-AMS360
Install-Net48
Install-Web2View
Install-WorkSmart

This will install all the software components.

<#
.SYNOPSIS
Generates a temporary file path for a given file name.

.DESCRIPTION
This function uses the .NET method System.IO.Path.GetTempPath() to get the path to the temporary files directory, and then appends the provided file name to this path.

.PARAMETER FileName
The name of the file for which to generate a temporary file path.

.EXAMPLE
Get-TempFilePath -FileName "temp.txt"

This will return a string representing a path to a file named "temp.txt" in the temporary files directory.

.NOTES
The returned path does not guarantee that the file exists, it only provides a valid path in the temporary directory.
#>
function Get-TempFilePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    $TempDirectory = [System.IO.Path]::GetTempPath()
    return (Join-Path -Path $TempDirectory -ChildPath $FileName)
}

<#
.SYNOPSIS
Downloads a file from a given URL and starts a process with the downloaded file.

.DESCRIPTION
This function downloads a file from the provided URL to a temporary location, and then starts a process with the downloaded file using the provided arguments.

.PARAMETER DownloadURL
The URL from which to download the file.

.PARAMETER FileName
The name to give to the downloaded file.

.PARAMETER Arguments
The arguments to pass to the process started with the downloaded file.

.EXAMPLE
Download-And-StartProcess -DownloadURL "https://example.com/file.zip" -FileName "file.zip" -Arguments "/s"

This will download the file from "https://example.com/file.zip", save it as "file.zip" in the temporary files directory, and start a process with this file using the "/s" argument.

.NOTES
The process is started in a wait state, meaning that the function will not return until the process has exited.
#>
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

<#
.SYNOPSIS
Installs TransactNOW application.

.DESCRIPTION
This function installs the TransactNOW application by downloading the setup file from the specified URL and starting the installation process.

.PARAMETER TransactNowURL
The URL of the TransactNOW setup file. The default value is "https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/TransactNOW Setup.exe".

.EXAMPLE
Install-TransactNow -TransactNowURL "https://example.com/TransactNOW_Setup.exe"
Downloads the TransactNOW setup file from the specified URL and starts the installation process.

#>
function Install-TransactNow {
    param (
        [string]$TransactNowURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/TransactNOW Setup.exe'
    )
    Invoke-DownloadAndStartProcess -DownloadURL $TransactNowURL -FileName 'TransactNowSetup.exe' -Arguments '-q'
}

function Install-PowerAutomate {
    param (
        [string]$DownloadURL = 'https://go.microsoft.com/fwlink/?linkid=2102613'
    )

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'PowerAutomate.exe' -Arguments '-Install -AcceptEULA -Silent'
}

function Install-BenefitPoint {
    param (
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/EStatement/eStatement 4.0.0.31.msi'
    )

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'eStatement.msi' -Arguments '/qn'
}

<#
.SYNOPSIS
    Installs Claros software components.

.DESCRIPTION
    This function installs the Claros software components by downloading and running the required setup files.

.PARAMETER actuarialUrl
    The URL of the Actuarial Assistant setup file.

.PARAMETER clarosUrl
    The URL of the Claros Reserve setup file.

.PARAMETER ExperienceUrl
    The URL of the Experience Migration setup file.

.PARAMETER RiskDecisionUrl
    The URL of the Risk Decision Support setup file.

.EXAMPLE
    Install-Claros -actuarialUrl "https://example.com/ActuarialAssistantSetup.exe" -clarosUrl "https://example.com/ClarosReserveSetup.exe" -ExperienceUrl "https://example.com/ExperienceMigrationSetup.exe" -RiskDecisionUrl "https://example.com/RiskDecisionSupportSetup.exe"
    Installs the Claros software components using the specified URLs.

#>
function Install-Claros {
    param (
        [string]$actuarialUrl = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Claros Install Software/ActuarialAssistantSetup_522_64.exe',
        [string]$clarosUrl = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Claros Install Software/ClarosReserveSetup22_64.exe',
        [string]$ExperienceUrl = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Claros Install Software/ExperienceMigrationSetup_522_64.exe',
        [string]$RiskDecisionUrl = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Claros Install Software/RiskDecisionSupportSetup_522_64.exe'
    )

    Invoke-DownloadAndStartProcess -DownloadURL $actuarialUrl -FileName 'ActuarialAssistantSetup_522_64.exe' -Arguments '/S /v/qn'
    Invoke-DownloadAndStartProcess -DownloadURL $clarosUrl -FileName 'ClarosReserveSetup22_64.exe' -Arguments '/S /v/qn'
    Invoke-DownloadAndStartProcess -DownloadURL $ExperienceUrl -FileName 'ExperienceMigrationSetup_522_64.exe' -Arguments '/S /v/qn'
    Invoke-DownloadAndStartProcess -DownloadURL $RiskDecisionUrl -FileName 'RiskDecisionSupportSetup_522_64.exe' -Arguments '/S /v/qn'

    if (Test-Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Claros Analytics') {
        Remove-Item 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Claros Analytics' -Force -Recurse -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Installs the Cobra application.

.DESCRIPTION
The Install-Cobra function downloads and installs the Cobra application from the specified URL.

.PARAMETER DownloadURL
The URL from which to download the Cobra installation file. The default value is "https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Cobra Install/CSISysFilesInstall.exe".

.EXAMPLE
Install-Cobra -DownloadURL "https://example.com/cobra_installer.exe"
Downloads and installs the Cobra application from the specified URL.

#>
function Install-Cobra {
    param(
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/Cobra Install/CSISysFilesInstall.exe'
    )
    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'CSISysFilesInstall.exe' -Arguments '/S /v/qn'
}

<#
.SYNOPSIS
    Installs the Producer Plus application.

.DESCRIPTION
    The Install-ProducerPlus function downloads the Producer Plus application from a specified URL, extracts the contents, and installs it silently on the local machine. It also removes any existing shortcuts or start menu entries for the application.

.PARAMETER DownloadURL
    Specifies the URL from which to download the Producer Plus application. The default value is "https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/ProducerPlus19.1/ProducerPlus.zip".

.EXAMPLE
    Install-ProducerPlus -DownloadURL "https://example.com/ProducerPlus.zip"
    Downloads the Producer Plus application from the specified URL and installs it.
#>
function Install-ProducerPlus {
    param(
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/ProducerPlus19.1/ProducerPlus.zip'
    )

    $TempFilePath = Get-TempFilePath -FileName 'ProducerPlus.zip'
    Invoke-WebRequest -Uri $DownloadURL -OutFile $TempFilePath
    $Path = Split-Path $TempFilePath
    Expand-Archive -Path $TempFilePath -DestinationPath $Path -Force
    Start-Process "$Path\ProducerPlus\ClientSetup.msi" -ArgumentList '/qn' -Wait

    if (Test-Path 'C:\Users\Public\Desktop\Producer Plus 19.1.lnk') {
        Remove-Item 'C:\Users\Public\Desktop\Producer Plus 19.1.lnk' -Force
    }
    if (Test-Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Producer Plus') {
        Remove-Item 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Producer Plus' -Force -Recurse
    }
}

<#
.SYNOPSIS
    Installs PSQL client.

.DESCRIPTION
    This function downloads and installs the PSQL client from the specified URL.

.PARAMETER DownloadURL
    The URL from which to download the PSQL client. Default value is "https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/PSQL client/PSQL.zip".

.EXAMPLE
    Install-PSQL -DownloadURL "https://example.com/PSQL.zip"
    Downloads and installs the PSQL client from the specified URL.

#>
function Install-PSQL {
    param(
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/PSQL client/PSQL.zip'
    )

    $TempFilePath = Get-TempFilePath -FileName 'PSQL.zip'
    Invoke-WebRequest -Uri $DownloadURL -OutFile $TempFilePath
    $Path = Split-Path $TempFilePath
    Expand-Archive -Path $TempFilePath -DestinationPath $Path -Force
    Start-Process "$Path\PSQL\ActianCache\PSQL13.20\PSQL - Windows\Data\SetupClient64_x64.exe" -ArgumentList '/s /w /v/qn' -Wait
}

function Install-Nasa {
    param(
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/nasa.exe'
    )

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'nasa.exe' -Arguments '/S /v/qn'

    if (Test-Path 'C:\Users\Public\Desktop\Eclipse 6.2.lnk') {
        Remove-Item 'C:\Users\Public\Desktop\Eclipse 6.2.lnk' -Force
    }
    if (Test-Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Eclipse 6.2') {
        Remove-Item 'C:\ProgramData\Microsoft\Windows\Start Menu\Eclipse 6.2' -Force -Recurse
    }
}

function Invoke-AgentInstall {
    $ScriptUrl = "https://raw.githubusercontent.com/mwandell-hilbgroup/HilbgroupAutomation/refs/heads/main/AVDImageInstallation/Pools/PostBootApplications.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Write-Host "Installing Chocolatey Packages"
Install-ChocoPackages -Packages @('powerbi')

Write-Host "Installing LastPass"
Install-LastPass

Write-Host "Installing TransactNow"
Install-TransactNow

Write-Host "Installing Power Automate"
Install-PowerAutomate

Write-Host "Installing BenefitPoint"
Install-BenefitPoint

Write-Host "Installing Claros"
Install-Claros

Write-Host "Installing Cobra"
Install-Cobra

Write-Host "Installing Producer Plus"
Install-ProducerPlus

Write-Host "Installing PSQL"
Install-PSQL

Write-Host "Installing NASA"
Install-Nasa

Write-Host "Installing Agents"
Invoke-AgentInstall