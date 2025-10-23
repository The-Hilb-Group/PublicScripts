$ProgressPreference = 'SilentlyContinue'

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
        [string]$AMS360WebURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/AMS360ClientInstaller-Rev12.msi'
    )
    Invoke-DownloadAndStartProcess -DownloadURL $AMS360WebURL -FileName 'AMS360ClientInstallerRev12.msi' -Arguments '/qn'

    if (Test-Path -Path 'C:\users\Public\Desktop\Install TransactNow.url') {
        Remove-Item -Path 'C:\users\Public\Desktop\Install TransactNow.url' -Force
    }
    if (Test-Path -Path 'C:\users\Public\Desktop\ImageRight Connect 7.0.106.1787.lnk') {
        Remove-Item -Path 'C:\users\Public\Desktop\ImageRight Connect 7.0.106.1787.lnk' -Force
    }
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

function Add-ExtensionPolicy {
    param (
        [string]$Browser,
        [string]$ExtensionID
    )

    $UpdateURL = "https://clients2.google.com/service/update2/crx"

    # Determine registry path
    switch ($Browser.ToLower()) {
        "chrome" { $RegPath = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist" }
        "edge" { $RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist" }
        default { Write-Warning "Unknown browser: $Browser"; return }
    }

    # Create registry key if missing
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    # Build value string
    $Value = "$ExtensionID;$UpdateURL"

    # Read existing entries
    $ExistingItem = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue

    if ($null -ne $ExistingItem) {
        $ExistingProps = $ExistingItem | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
        $ExistingNumbers = $ExistingProps | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    }


    # Check for duplicates
    $Duplicate = $false
    foreach ($Prop in $ExistingProps) {
        $PropValue = (Get-ItemProperty -Path $RegPath -Name $Prop -ErrorAction SilentlyContinue).$Prop
        if ($PropValue -eq $Value) {
            Write-Host "$Browser extension already exists under entry '$Prop': $ExtensionID"
            $Duplicate = $true
            break
        }
    }

    if (-not $Duplicate) {
        $NextNumber = if ($ExistingNumbers) { ($ExistingNumbers | Measure-Object -Maximum).Maximum + 1 } else { 1 }
        New-ItemProperty -Path $RegPath -Name $NextNumber -Value $Value -PropertyType String -Force | Out-Null
        Write-Host "Added $Browser extension entry #$NextNumber → $ExtensionID"
    }
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

    $PrinterUrl = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/ImageRight/ImageRight.PDFPrinter.64.msi"

    Invoke-DownloadAndStartProcess -DownloadURL $PrinterUrl -FileName "imageRight.PDFPrinter.64.msi" -Arguments '/qn'

    $Extensions = @{
        "Chrome" = @(
            "lmjkddpocmpfpfelefmjeikplccmchaj"  # Chrome extension ID
        )
        "Edge"   = @(
            "bbcadncpbhofkhfbpokeflalmknkfjip"  # Edge extension ID
        )
    }

    foreach ($Browser in $Extensions.Keys) {
        foreach ($ExtensionID in $Extensions[$Browser]) {
            Add-ExtensionPolicy -Browser $Browser -ExtensionID $ExtensionID
        }
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

function Disable-WindowsStoreResults {
    $SearchPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path $SearchPath)) {
        New-Item -Path $SearchPath -Force | Out-Null
    }

    New-ItemProperty -Path $SearchPath -Name "DisableSearchBoxSuggestions" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $SearchPath -Name "DisableWebSearch" -Value 1 -PropertyType DWord -Force | Out-Null

    Write-Host "Disabled Windows Store and web results in Start menu search (All Users)."

}

function Install-Office {
    $ScriptUrl = "https://raw.githubusercontent.com/The-Hilb-Group/PublicScripts/refs/heads/main/AVDImageInstallation/ImageDeployment/InstallOffice32Bit.ps1"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($ScriptUrl))
}

Enable-WindowsOptionalFeature -Online -FeatureName 'NetFx3'

Write-Host "Installing Chocolatey"
Install-Chocolatey

Write-Host "Installing Chocolatey Packages"
Install-ChocoPackages -Packages @('googlechrome', 'notepadplusplus', '7zip', 'vlc')

Write-Host "Installing Adobe Acrobat"
Install-AdobeAcrobat

Write-Host "Installing AMS360"
Install-AMS360

Write-Host "Installing ImageRight"
Install-ImageRight

Write-Host "Removing Quick Assist"
Remove-QuickAssist

Write-Host "Setting Time Zone to Eastern Standard Time"
Set-TimeZone -Name 'Eastern Standard Time'

Write-Host "Disabling OOBE"
Disable-OOBESteps

Write-Host "Disabling Windows Store Results"
Disable-WindowsStoreResults

Write-Host "Installing Office"
Install-Office