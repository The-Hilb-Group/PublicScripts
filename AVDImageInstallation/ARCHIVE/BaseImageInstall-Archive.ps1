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
Installs Chocolatey on the system.

.DESCRIPTION
This function installs Chocolatey, a package manager for Windows. It does this by setting the execution policy to bypass for the current process, and then invoking the Chocolatey installation script from 'https://chocolatey.org/install.ps1'.

.EXAMPLE
Install-Chocolatey

This will install Chocolatey on the system.

.NOTES
The function sets the execution policy to bypass for the current process. This means that the execution policy will be reset to its previous value when the current process exits.
#>
function Install-Chocolatey {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
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
Installs Adobe Acrobat.

.DESCRIPTION
This function downloads Adobe Acrobat from the provided URL, extracts the downloaded file, downloads a transform file, and then installs Adobe Acrobat using the setup file and the transform file.

.PARAMETER AdobeAcrobatWebURL
The URL from which to download Adobe Acrobat.

.PARAMETER AdobeTransformURL
The URL from which to download the transform file.

.EXAMPLE
Install-AdobeAcrobat

This will install Adobe Acrobat.

.NOTES
The function waits for the installation process to complete before returning.
#>
function Install-AdobeAcrobat {
    param (
        [string]$AdobeAcrobatWebURL = 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip',
        [string]$AdobeTransformURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-avd-deployment-scripts/AVD_Image_Deployments/AcroPro.mst'
    )
    $TempFilePath = Get-TempFilePath -FileName 'AdobeAcrobatWebURL.zip'
    $TempDirectory = (Split-Path -Path $TempFilePath -Parent)
    $AcrobatPath = "$TempDirectory\Adobe Acrobat"

    # Download the file
    Invoke-WebRequest -Uri $AdobeAcrobatWebURL -OutFile $TempFilePath

    # Extract the file
    Expand-Archive -Path $TempFilePath -DestinationPath $TempDirectory -Force

    # Download transformFile
    Invoke-WebRequest -Uri $AdobeTransformURL -OutFile "$AcrobatPath\Transforms\AcroPro.mst"

    # Install Adobe Acrobat
    Start-Process -FilePath "$AcrobatPath\setup.exe" -ArgumentList '/sAll /rs /msi  EULA_ACCEPT=YES LANG_LIST=en_US UPDATE_MODE=0 DISABLE_ARM_SERVICE_INSTALL=1 ADD_THUMBNAILPREVIEW=YES' -Wait
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

<#
.SYNOPSIS
Installs AMS360.

.DESCRIPTION
This function downloads AMS360 from the provided URL and then installs it.

.PARAMETER AMS360WebURL
The URL from which to download AMS360.

.EXAMPLE
Install-AMS360

This will install AMS360.

.NOTES
The function uses the Invoke-DownloadAndStartProcess function to download and install AMS360.
#>
function Install-AMS360 {
    param (
        [string]$AMS360WebURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/AMS360ClientInstaller-Rev12.msi%22'
    )
    Invoke-DownloadAndStartProcess -DownloadURL $AMS360WebURL -FileName 'AMS360ClientInstallerRev11.msi' -Arguments '/qn'

    if (Test-Path -Path 'C:\users\Public\Desktop\Install TransactNow.url') {
        Remove-Item -Path 'C:\users\Public\Desktop\Install TransactNow.url' -Force
    }
    if (Test-Path -Path 'C:\users\Public\Desktop\ImageRight Connect 7.0.106.1787.lnk') {
        Remove-Item -Path 'C:\users\Public\Desktop\ImageRight Connect 7.0.106.1787.lnk' -Force
    }
}

<#
.SYNOPSIS
Installs .NET Framework 4.8.

.DESCRIPTION
This function checks if .NET Framework 4.8 or later is already installed, and if not, downloads it from the provided URL and then installs it.

.PARAMETER DownloadURL
The URL from which to download .NET Framework 4.8.

.EXAMPLE
Install-Net48

This will install .NET Framework 4.8.

.NOTES
The function uses the Invoke-DownloadAndStartProcess function to download and install .NET Framework 4.8.
#>
function Install-Net48 {
    param (
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/ndp48-x86-x64-allos-enu.exe'
    )
    if ($null -ne (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\*' | Where-Object { $_.Version -ge 4 })) {
        return
    }
    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'ndp48-x86-x64-allos-enu.exe' -Arguments '/q /norestart'
}

<#
.SYNOPSIS
Installs Microsoft Edge WebView2 Runtime.

.DESCRIPTION
This function checks if Microsoft Edge WebView2 Runtime is already installed, and if not, downloads it from the provided URL and then installs it.

.PARAMETER DownloadURL
The URL from which to download Microsoft Edge WebView2 Runtime.

.EXAMPLE
Install-Web2View

This will install Microsoft Edge WebView2 Runtime.

.NOTES
The function uses the Invoke-DownloadAndStartProcess function to download and install Microsoft Edge WebView2 Runtime.
#>
function Install-Web2View {
    param (
        [string]$DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/MicrosoftEdgeWebView2RuntimeInstallerX86.exe'
    )

    if ($null -ne (Get-ItemProperty HKLM:\SOFTWARE\Classes\Installer\Products\* | Where-Object { $_.ProductName -match 'Webview 2 32bit' })) {
        return
    }
    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'MicrosoftEdgeWebView2RuntimeInstallerX86.exe' -Arguments '/silent /install'
}

<#
.SYNOPSIS
Installs WorkSmart.

.DESCRIPTION
This function installs WorkSmart. It creates a batch script that runs the WorkSmart installer, waits for a certain period, kills any running msiexec.exe processes, waits again, and then downloads two configuration files. The function then runs the batch script, waits for 5 minutes, stops all services starting with ImageRight, removes the downloaded configuration files, downloads the configuration files again, and finally starts all services starting with ImageRight.

.EXAMPLE
Install-WorkSmart

This will install WorkSmart.

.NOTES
The function uses Write-Host to output status messages to the console, Start-Sleep to pause execution of the script for a specified number of seconds, Get-Service to retrieve the status of services, Stop-Service to stop services, Remove-Item to delete files, and Start-BitsTransfer to download files.
#>
function Install-WorkSmart {
    $Body = @'
setlocal enabledelayedexpansion

"C:\HILB\WorkSmartInstaller.exe" /exenoui /qn VID="3033888" SSL="1" ALLUSERS="1"
waitfor SomethingThatIsNeverHappening /t 15 >nul 2>&1
taskkill /im msiexec.exe /f

waitfor SomethingThatIsNeverHappening /t 60 >nul 2>&1
cd "C:\Program Files (x86)\ImageRight\Clients\"
curl -o imageright.desktop.exe.config "https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/imageright.desktop.exe.config"
cd "C:\Program Files (x86)\ImageRight\InstallerService\"
curl -o IRInstallerService.exe.config "https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/thgx-IRInstallerService.exe.config"
'@

    if (-not (Test-Path -Path 'C:\Hilb')) {
        New-Item -ItemType Directory -Path 'C:\Hilb'
    }
    Invoke-WebRequest -Uri 'https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/WorkSmart%20Installer.exe' -OutFile 'C:\Hilb\WorkSmartInstaller.exe'
    Set-Content 'C:\hilb\ir.bat' $Body

    Write-Host 'Waiting for Installation to complete. Pausing for 5 minutes.'
    Start-Process -FilePath 'C:\Windows\System32\cmd.exe' -Verb RunAs -ArgumentList '/c C:\hilb\ir.bat'
    Start-Sleep -Seconds 60
    for ($i = 4; $i -gt 0; $i--) {
        Write-Host "Waiting for Installation to complete. Pausing for $i minutes."
        Start-Sleep -Seconds 60
    }

    Write-Host 'Stopping ImageRight Service and updating Desktop and Installer service configs'
    for ($i = 5; $i -gt 0; $i--) {
        Write-Host "Waiting for Installation to complete. Pausing for $i minutes."
        Start-Sleep -Seconds 60
    }

    Get-Service ImageRight* | Stop-Service -Force
    Write-Host 'Removing Files'
    Remove-Item -Path 'C:\Program Files (x86)\ImageRight\Clients\imageright.desktop.exe.config' -Force
    Remove-Item -Path 'C:\Program Files (x86)\ImageRight\InstallerService\IRInstallerService.exe.config' -Force
    Write-Host 'Downloading new files'
    Start-BitsTransfer -Source 'https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/thgx-IRInstallerService.exe.config' -Destination 'C:\Program Files (x86)\ImageRight\InstallerService\IRInstallerService.exe.config'
    Start-BitsTransfer -Source 'https://eusthginfrastructure.blob.core.windows.net/thg-remediation-scripts/imageright.desktop.exe.config' -Destination 'C:\Program Files (x86)\ImageRight\Clients\imageright.desktop.exe.config'

    Write-Host 'Starting Service'
    Get-Service ImageRight* | Start-Service
    Get-Service ImageRight*
}

<#
.SYNOPSIS
Installs ImageRight and its dependencies.

.DESCRIPTION
This function installs ImageRight and its dependencies, which include .NET 4.8, Web2View, and WorkSmart.

.EXAMPLE
Install-ImageRight

This will install ImageRight and its dependencies.

.NOTES
If any of the installations fail, an error will be written to the error stream.
#>
function Install-ImageRight {
    Install-Net48
    Install-Web2View
    Install-WorkSmart
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

function Remove-QuickAssist {
    $checkQuickAssist = Get-WindowsCapability -Online | Where-Object { $_.name -like '*QuickAssist*' }

    if ($checkQuickAssist.state -eq 'Installed') {
        try {
            Remove-WindowsCapability -Online -Name $checkQuickAssist.name -ErrorAction Stop
        } catch {
            $error[0].Exception.Message
        }
    }
}

function Disable-OOBESteps {
    $registryPaths = @{
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"            = @{
            "DisablePrivacyExperience" = 1
            "DisableVoice"             = 1
            "PrivacyConsentStatus"     = 1
            "Protectyourpc"            = 3
            "HideEULAPage"             = 1
        }
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" = @{
            "EnableFirstLogonAnimation" = 1
        }
    }

    foreach ($path in $registryPaths.Keys) {
        foreach ($name in $registryPaths[$path].Keys) {
            New-ItemProperty -Path $path -Name $name -Value $registryPaths[$path][$name] -PropertyType DWord -Force
        }
    }
}

#Region Main Customization Program

Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3'

Write-Host "Installing Chocolatey"
Install-Chocolatey

Write-Host "Installing Chocolatey Packages"
Install-ChocoPackages -Packages @('googlechrome', 'notepadplusplus', '7zip', 'vlc', 'powerbi')

Write-Host "Installing Adobe Acrobat"
Install-AdobeAcrobat

Write-Host "Installing AMS360"
Install-AMS360

Write-Host "Istalling ImageRight"
Install-ImageRight

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

Write-Host "Removing Quick Assist"
Remove-QuickAssist

Write-Host "Setting Time Zone to Eastern Standard Time"
Set-TimeZone -Name 'Eastern Standard Time'

Write-Host "Disabling OOBE"
Disable-OOBESteps
#EndRegion
