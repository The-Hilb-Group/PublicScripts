$CheckFilePath = "C:\Program Files\SmartDeploy\ClientService\SDClientService.exe"
$DownloadUrl = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/SDClientSetup-cloudonly.msi"
$AppPath = "C:\HILB\SDClientSetup-cloudonly.msi"
$Path = "c:\hilb"
$ServiceName = "SDClientService"
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
            "HKCR:\Installer\Products\0ABA56F08921639418A88330E257C2B7"
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0F65ABA0-1298-4936-818A-38032E752C7B}"
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

function Uninstall-SmartDeploy {
    $exitCode = -1
    $SDRegistry = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall" | Where-Object { $_.GetValue("DisplayName") -like "*SmartDeploy*" }
    if ($SDRegistry) {
        $uninstallCommand = $SDRegistry.GetValue("UninstallString")
        if ($uninstallCommand) {
            $uninstallCommand = $uninstallCommand -replace "msiexec.exe", ""
            $process = Start-Process -File "msiexec.exe" -ArgumentList "$uninstallCommand /qn /norestart" -Wait -PassThru
            $exitCode = $process.ExitCode
        }
    }
    return $exitCode
}

function Get-InstallerVersion {
    param (
        [string] $MSIPath
    )
    $windowsInstaller = New-Object -com WindowsInstaller.Installer
    $database = $windowsInstaller.GetType().InvokeMember(
        "OpenDatabase", "InvokeMethod", $Null,
        $windowsInstaller, @($MSIPath, 0)
    )

    $q = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
    $View = $database.GetType().InvokeMember(
        "OpenView", "InvokeMethod", $Null, $database, ($q)
    )

    $View.GetType().InvokeMember("Execute", "InvokeMethod", $Null, $View, $Null)
    $record = $View.GetType().InvokeMember("Fetch", "InvokeMethod", $Null, $View, $Null)
    $versionInfo = ($record.GetType().InvokeMember("StringData", "GetProperty", $Null, $record, 1))

    # Close the database and release resources
    $View.GetType().InvokeMember("Close", "InvokeMethod", $Null, $View, $Null)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($View) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($record) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) | Out-Null
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($windowsInstaller) | Out-Null

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    return [Version]$($versionInfo)
}

function Install-SmartDeploy {
    param (
        [Parameter()]
        [string] $MSIPath
    )
    Write-Information "Starting Installation of SmartDeploy Client..."

    $startTime = Get-Date
    $timeout = [TimeSpan]::FromMinutes(2)

    while (Get-Process -Name msiexec -ErrorAction SilentlyContinue) {
        $elapsedTime = (Get-Date) - $startTime
        $remainingTime = $timeout - $elapsedTime

        if ($elapsedTime -ge $timeout) {
            Write-Error "Timeout reached while waiting for another installation to complete."
            return 1618 # Return the MSI error code for another installation in progress
        }
        Write-Information "Another installation is in progress. Waiting... Remaining time: $([math]::Round($remainingTime.TotalSeconds)) seconds."
        Start-Sleep -Seconds 5
    }

    $process = Start-Process msiexec -ArgumentList "/i $MSIPath /qn /norestart" -PassThru -Wait

    return $process.ExitCode
}

function Test-SmartDeployInstall {
    param (
        [string] $CheckFilePath,
        [System.Version]$DownloadedVersion
    )

    if (!(Test-Path $CheckFilePath)) {
        Write-Information "SmartDeploy Client is not installed."
        return 0
    }
    $CurrentVersion = [System.Version](Get-Item $CheckFilePath -ErrorAction 'SilentlyContinue').VersionInfo.FileVersion

    if ($CurrentVersion -ge $DownloadedVersion) {
        Write-Information "SmartDeploy Installed Successfully"
        return 1
    }
    else {
        Write-Information "SmartDeploy Installation Failed or Version Mismatch"
        return -1
    }
}

try {
    ## Create necessary directory if it doesn't exist
    If (!(Test-Path -PathType Container $Path)) {
        New-Item -ItemType Directory -Path $Path
    }

    ## Remove previous installer if exists
    If (Test-Path -Path $AppPath) {
        Remove-Item -Path $AppPath -Force
    }

    ## Download the SDClient installer from the URL
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $AppPath
    $ProgressPreference = 'Continue'

    ## Get version of the downloaded MSI installer
    if (!(Test-Path $AppPath)) {
        Write-Information "$AppPath does not exist. Did the download fail?"
        Exit
    }


    if (Test-Path -Path $CheckFilePath) {
        $InstalledVersion = [system.version](Get-Item $CheckFilePath).VersionInfo.FileVersion
    }
    else {
        $InstalledVersion = [System.Version]"0.0.0.0"
    }

    $DownloadedVersion = Get-InstallerVersion -MSIPath $AppPath
    $DownloadedVersion = [System.Version]$("{0}.{1}.{2}.{3}" -f $DownloadedVersion.Major, $DownloadedVersion.Minor, $DownloadedVersion.Build, $DownloadedVersion.Revision)

    if ($InstalledVersion -ge $DownloadedVersion) {
        Write-Information "Installed version ($InstalledVersion) is greater than or equal to downloaded version ($DownloadedVersion). No action needed."
        Exit
    }
    elseif ($InstalledVersion -eq [System.Version]"0.0.0.0") {
        Write-Information "Proceeding with installation, not currently installed."
    }
    else {
        Write-Information "Proceeding with installation, newer version detected."
        $statusCode = Uninstall-SmartDeploy -ServiceName $ServiceName -InstalledVersion $InstalledVersion -AppPath $AppPath
        if ($statusCode -ne 0) {
            Write-Information "Uninstallation failed with exit code $statusCode."
            Write-Information "Will attempt to remove any failed installations."
        }
    }

    Remove-FailedInstallation
    $InstallCode = Install-SmartDeploy -MSIPath $AppPath
    if ($InstallCode -ne 0) {
        Write-Information "Installation failed with exit code $InstallCode."
    }

    $TestStatus = Test-SmartDeployInstall -CheckFilePath $CheckFilePath -DownloadedVersion $DownloadedVersion

    switch ($TestStatus) {
        -1 {
            Install-SmartDeploy -MSIPath $AppPath | Out-Null
            if (Test-SmartDeployInstall -CheckFilePath $CheckFilePath -DownloadedVersion $DownloadedVersion -eq 1) {
                Write-Information "SmartDeploy Client was successfully updated to version $DownloadedVersion."
                Exit 0
            }
            else {
                Write-Information "SmartDeploy Client update failed. Manual intervention required."
                Exit 1
            }
        }
        0 {
            $InstallCode = Install-SmartDeploy -MSIPath $AppPath
            if ($InstallCode -ne 0) {
                Write-Information "Installation failed with exit code $InstallCode."
                Exit $InstallCode
            }
        }
        1 {
            Write-Information "SmartDeploy Client is successfully installed with version $DownloadedVersion."
            Exit 0
        }
    }
}
finally {
    Write-Information "Cleaning up..."
    Write-Information "Stopping MSI Processes"
    Get-Process msiexec -ErrorAction SilentlyContinue | Stop-Process
    if (Test-Path $AppPath) {
        Write-Information "Removing installer file $AppPath..."
        Remove-Item -Path $AppPath -Force
    }
}
