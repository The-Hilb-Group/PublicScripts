$CheckFilePath = "C:\Program Files\SmartDeploy\ClientService\SDClientService.exe"
$DownloadUrl = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/SDClientSetup-cloudonly.msi"
$AppPath = "C:\HILB\SDClientSetup-cloudonly.msi"
$Path = "c:\hilb"
$ServiceName = "SDClientService"
$TargetVersion = "3.0.2060.1239"
$InformationPreference = 'Continue'

function Remove-FailedInstallation {
    try {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null

        $PathsToRemove = @(
            "HKCR:\AppID\{68588B7E-9DA7-4D29-9292-1ADAE1CA1192}",
            "HKCR:\AppID\SmartDeploy.EXE",
            "HKCR:\Installer\Products\0A4F77B87FDAA124F9BADE052B7F4A85",
            "HKCR:\Installer\Products\16EDC03CA8666B045AD49370A1CB101C",
            "HKCR:\Installer\Products\F588D9A7B92AFE44B9B6D41CD21F61BC",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{7A9D885F-A29B-44EF-9B6B-4DC12DF116CB}\InstallSource",
            "HKCR:\Installer\Products\3AE76BCF86EC85440B8F34C385BF2E35",
            "HKCR:\Installer\Products\772106ECC43E9A24BB17897E19538208",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{CE601277-E34C-42A9-BB71-98E791352880}\InstallSource",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Appmgmt\{09427150-57f9-4d1c-829d-96db1299e5d3}",
            "HKLM:\SYSTEM\ControlSet001\Services\EventLog\Application\SmartDeploy",
            "HKLM:\SYSTEM\ControlSet001\Services\EventLog\Application\SmartDeploy Client Service",
            "HKLM:\SYSTEM\ControlSet001\Services\EventLog\Application\SmartDeploy Console/Client Service",
            "HKLM:\SYSTEM\ControlSet001\Services\SmartDeploy",
            "HKLM:\SYSTEM\Setup\FirstBoot\Services\SmartDeploy",
            "HKCR:\Installer\Products\A325E1EDF41A10140A46F166D3BC7EBC",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{DE1E523A-A14F-4101-A064-1F663DCBE7CB}\InstallSource",
            "HKCR:\Installer\Products\15389F7137F1E0F4CB120CE8C319330C",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{17F98351-1F73-4F0E-BC21-C08E3C9133C0}\InstallSource",
            "C:\Windows\SysWOW64\SmartDeploy.dll",
            "C:\Windows\System32\SmartDeploy.dll",
            "C:\Windows\SysWOW64\SmartDeploy.exe",
            "C:\Windows\System32\SmartDeploy.exe",
            "HKCR:\Installer\Products\0ABA56F08921639418A88330E257C2B7",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0F65ABA0-1298-4936-818A-38032E752C7B}",
            "HKCR:\Installer\Products\96029F5716AA7B74F83EBF3207B0DEF6",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{75F92069-AA61-47B7-8FE3-FB23700BED6F}"
        )

        foreach ($p in $PathsToRemove) {
            try {
                if (Test-Path $p) {
                    Remove-Item -Path $p -Recurse -Force -Confirm:$false -ErrorAction Stop
                }
            }
            catch {
                Write-Warning "Failed to remove $($p): $($_.Exception.Message)"
            }
        }

        Remove-Item -Path "C:\Windows\SysWOW64\SmartDeploy" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    finally {
        if (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name HKCR -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-SDClient {
    $exitCode = -1

    $entries = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValue("DisplayName") -like "*SmartDeploy*" }

    foreach ($entry in $entries) {
        $uninstallCommand = $entry.GetValue("UninstallString", $null)
        if (-not $uninstallCommand) { continue }

        # Remove msiexec.exe safely (case-insensitive, trims spacing)
        $uninstallCommand = $uninstallCommand -replace "(?i)msiexec\.exe\s*", ""

        $process = Start-Process -FilePath "msiexec.exe" `
            -ArgumentList "$uninstallCommand /qn /norestart" `
            -Wait -PassThru

        $exitCode = $process.ExitCode
    }

    return $exitCode
}

function Check-SDVersion {


    $detectedApp = "SmartDeploy Client"  
    
    $RequiredVersion = $TargetVersion

    $app = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $DetectedApp }
    if ($app) {
        $script:DetectedVersion = $app.Version
        if ($DetectedVersion -eq $TargetVersion) {
            Write-Host "App is installed with version $DetectedVersion, terminating."
            #exit
        } else {
            Write-Host "App is installed with version $DetectedVersion, which is less than $RequiredVersion, proceeding with install."
        }
    } else {
        Write-Host "App not detected, proceeding with install."
    }
}

function Download-SDClient {

    $ProgressPreference = 'SilentlyContinue'
    Write-Host "Downloading SD Installer" -ForegroundColor Cyan
    $outputPath = Join-Path $Path "SDClientSetup-cloudonly.msi"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $outputPath
    $ProgressPreference = 'Continue'
}


function Test-DownloadIntegrity {
    #param (
    #    [string]$DownloadUrl,
    #    [string]$AppPath
    #)
    #

    try {
        Write-Host "Comparing file on server to downloaded file..." -ForegroundColor Cyan
        $response = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to reach URL: $DownloadUrl" -ForegroundColor Red
        Write-Host $_.Exception.Message
        return $false
    }

    $contentLengthHeader = $response.Headers["Content-Length"]

    if (-not $contentLengthHeader) {
        Write-Host "Content-Length header missing. Cannot validate file size." -ForegroundColor Red
        return $false
    }

    $expectedSize = if ($contentLengthHeader -is [array]) {
        [int64]$contentLengthHeader[0]
    } else {
        [int64]$contentLengthHeader
    }

    if (-not (Test-Path $AppPath)) {
        Write-Host "$AppPath does not exist." -ForegroundColor Red
        return $false
    }

    $actualSize = (Get-Item $AppPath).Length

    $expectedSizeMB = [math]::Round($expectedSize / 1MB, 2)
    $actualSizeMB   = [math]::Round($actualSize / 1MB, 2)

    Write-Host ("Expected Size: {0} MB" -f $expectedSizeMB) -ForegroundColor Yellow
    Write-Host ("Actual Size:   {0} MB" -f $actualSizeMB) -ForegroundColor Yellow

    if ($actualSize -ne $expectedSize) {
        Write-Host "File sizes do not match! Terminating installation." -ForegroundColor Red
        return $false
    }

    Write-Host "File sizes match. Proceeding..." -ForegroundColor Green

}

function Install-SmartDeploy {


    if (-not (Test-Path -Path $AppPath -PathType Leaf)) {
        throw "MSI file not found: $AppPath"
    }

    $arguments = @(
        "/i"
        "`"$AppPath`""
        "/quiet"
        "/norestart"
        "ALLUSERS=1"
    )

    $process = Start-Process -FilePath "msiexec.exe" `
                             -ArgumentList $arguments `
                             -Wait -NoNewWindow -PassThru

    if ($process.ExitCode -ne 0) {
        throw "MSI installation failed with exit code $($process.ExitCode)"
    }

    return Write-Host "Installation completed successfully." -ForegroundColor Green
}

function SD-CleanUp {

    # Function to clean up installer files after installation is complete. 
    Write-Host "Cleaning up installer files..." -ForegroundColor Cyan
    Remove-Item -Path $AppPath -Force -ErrorAction SilentlyContinue
}


try {
    Start-Transcript "C:\Temp\Debug_SDClient.txt"

    Write-Host "Checking to see if SmartDeploy is already installed" -ForegroundColor Cyan
    Check-SDVersion

    #Uninstall-SDClient
    Write-Host "Running Cleanup of any failed installations..." -ForegroundColor Cyan
    Remove-FailedInstallation

    Download-SDClient

    Test-DownloadIntegrity

    Write-Host "Attempting to install SmartDeploy Client..." -ForegroundColor Cyan
    Install-SmartDeploy


    SD-CleanUp

    exit 0
}
catch {
    Write-Error "Installer Execution Failed. $($_.Exception.Message)"
    Write-Host "Attempting to stop running MSIEXEC processes and retry installation..." -ForegroundColor Yellow
    Get-Process msiexec | Stop-Process
    Write-Host "Retrying installation..." -ForegroundColor Cyan
    Install-SmartDeploy
    SD-CleanUp

    exit 1
}
finally {
    Stop-Transcript
}

