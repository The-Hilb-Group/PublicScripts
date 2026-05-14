function Check-AppVersion {

    # App to check will depend on preference. For example, if you want to check the desktop client, use "ImageRight Desktop" instead.
    # The version of the desktop client and browser plugin should always be the same, so either can be used to determine if the correct version of ImageRight is installed.
    # Required version is set to 25.1.1.x to allow for any patch versions of 25.1.1, but will need to be updated for future versions of ImageRight.

    $detectedApp = "ImageRight Adobe Plug-in"

    $RequiredVersion = "25.1.1.206"

    $app = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $DetectedApp }
    if ($app) {
        $script:DetectedVersion = $app.Version
        if ($DetectedVersion -eq "25.1.1.206") {
            Write-Host "App is installed with version $DetectedVersion, terminating."
            ##exit
        }
        else {
            Write-Host "App is installed with version $DetectedVersion, which is less than $RequiredVersion, proceeding with install."
        }
    }
    else {
        Write-Host "App not detected, proceeding with install."
    }
}


function Download-Installer {

    # Update the $URL variable to point to the location of the installer archive. The URL should point directly to a zip file, and the zip file should contain the individual MSIs at the root level or within a single parent folder.
    # Update the $ZipDirectory variable if you want to download and extract the installer files in a different location.

    $ProgressPreference = 'SilentlyContinue'
    Write-Host "Downloading IR Installer Files"
    $Directory = "C:\Temp"
    $url = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/IRAdobePlugin.msi"
    $outputPath = Join-Path $Directory "IRAdobePlugin.msi"
    Invoke-WebRequest -Uri $url -OutFile $outputPath
}



function Install-AdobePlugin {

    $MsiPath = "C:\temp\IRAdobePlugin.msi"

    if (-not (Test-Path -Path $MsiPath -PathType Leaf)) {
        throw "MSI file not found: $MsiPath"
    }

    $arguments = @(
        "/i"
        "`"$MsiPath`""
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

    return $true
}



function CleanUp {

    # Function to clean up installer files after installation is complete. This function deletes the extracted installer files and the downloaded zip file. The paths should be updated if the installer files are downloaded or extracted to a different location.

    Set-Location c:\temp

    try {
        Remove-Item -Path "c:\temp\IRAdobePlugin.msi" -Force -ErrorAction SilentlyContinue
    }
    catch {
        #Ignore
    }
}



try {
    Start-Transcript "C:\Temp\Debug_AdobePlugin.txt"

    Check-AppVersion

    $expandedRoot = "C:\Temp\"

    Write-Host "Expanded Path is $($expandedRoot)"

    Download-Installer

    Set-Location -LiteralPath $expandedRoot

    Install-AdobePlugin -ExpandedRoot $expandedRoot

    CleanUP

    exit 0
}
catch {
    Write-Error "Insaller Execution Failed. $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-Transcript
}
