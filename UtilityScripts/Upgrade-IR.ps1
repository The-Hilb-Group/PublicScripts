#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs / upgrades ImageRight 25R1 (Vertafore) and its companion components.

.DESCRIPTION
    Flow:
      1. Pre-checks (admin, C:\Temp, running apps)
      2. Detect installed version (registry, [version] comparison)
      3. Download installer zip and verify size against the size reported by the URL
      4. Expand archive and confirm every MSI / config file exists
      5. Uninstall previous ImageRight MSI products (only after payload is verified)
      6. Install MSIs in required order (each logged)
      7. Copy configs, restart installer service, apply folder permissions
      8. Cleanup (always runs)

    Exit codes:  0 = success / already current,  3010 = success, reboot required,  1 = failure

.NOTES
    Version      : 1.0.0 (BASELINE)
    Baseline date: 2026-10-06
    Target       : ImageRight 25R1 (Vertafore)

    Baseline behavior - changes from here should bump the version and be logged below:
      - Download is verified by comparing file size to the URL's Content-Length (no hash check).
      - BUILTIN\Users keeps FullControl on 'C:\Program Files (x86)\ImageRight' (Vertafore requirement).
      - Install order of MSIs is critical and must not change.
      - Browser extension policy push is disabled ($InstallBrowserExtensions = $false).
      - Up-to-date threshold is $RequiredVersion (25.1.1.0).

    Change log:
      1.0.0  2026-10-06  Baseline. Rewrite of original script: download/verify before uninstall,
                         registry-based version detection, per-MSI logging, 3010 reboot handling,
                         console progress output, cleanup in finally.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
$AppDisplayName   = 'ImageRight Desktop'          # Must match DisplayName in Add/Remove Programs exactly
$RequiredVersion  = [version]'25.1.1.204'           # Installed version >= this is treated as up to date
$TempRoot         = 'C:\Temp'
$ZipUrl           = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/25R1.zip'
$ZipPath          = Join-Path $TempRoot '25R1.zip'
$InstallerFolder  = Join-Path $TempRoot 'IR25R1'
$MsiLogFolder     = Join-Path $TempRoot 'ImageRightInstallLogs'
$TranscriptPath   = Join-Path $TempRoot 'Debug.txt'
$IRFolderPath     = 'C:\Program Files (x86)\ImageRight'
$IRServiceName    = 'ImageRightInstallerService'
$DownloadRetries  = 3

# Browser extension push is currently disabled (matches the original script).
# Set to $true to re-enable.
$InstallBrowserExtensions = $false

$script:RebootRequired = $false
$script:TotalSteps     = 8

# ----------------------------------------------------------------------------
# Console output helpers
# ----------------------------------------------------------------------------
function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Host ""
    Write-Host ("[{0}] [Step {1}/{2}] {3}" -f (Get-Date -Format 'HH:mm:ss'), $Number, $script:TotalSteps, $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Write-Ok {
    param([string]$Message)
    Write-Host ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host ("[{0}]     WARNING: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
}

# ----------------------------------------------------------------------------
# Pre-checks
# ----------------------------------------------------------------------------
function Initialize-Environment {
    if (-not (Test-Path -LiteralPath $TempRoot)) {
        New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $MsiLogFolder)) {
        New-Item -ItemType Directory -Path $MsiLogFolder -Force | Out-Null
    }

    # Windows PowerShell 5.1: make sure TLS 1.2 is available for the download
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Warn "Could not set TLS 1.2: $($_.Exception.Message)"
    }
}

function Stop-RunningApps {
    $irProcs = Get-Process -Name 'ImageRight*' -ErrorAction SilentlyContinue
    if ($irProcs) {
        Write-Info "Closing running ImageRight processes: $((($irProcs | Select-Object -ExpandProperty Name -Unique) -join ', '))"
        $irProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Office / Acrobat can block the add-in and plugin installers or force a reboot
    foreach ($name in 'OUTLOOK', 'WINWORD', 'EXCEL', 'Acrobat', 'AcroRd32') {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            Write-Warn "$name is running. The Microsoft/Adobe add-in installs may require a reboot."
        }
    }
}

# ----------------------------------------------------------------------------
# Version detection (registry based - avoids Win32_Product)
# ----------------------------------------------------------------------------
$UninstallRegistryPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Test-ImageRightUpToDate {
    $app = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $AppDisplayName } |
        Select-Object -First 1

    if (-not $app) {
        Write-Info "'$AppDisplayName' not detected. Proceeding with install."
        return $false
    }

    $installed = $null
    try { $installed = [version]$app.DisplayVersion } catch { }

    if (-not $installed) {
        Write-Warn "'$AppDisplayName' found but version '$($app.DisplayVersion)' could not be parsed. Proceeding with install."
        return $false
    }

    if ($installed -ge $RequiredVersion) {
        Write-Ok "'$AppDisplayName' version $installed is already at or above required version $RequiredVersion. Nothing to do."
        return $true
    }

    Write-Info "'$AppDisplayName' version $installed is older than required $RequiredVersion. Proceeding with upgrade."
    return $false
}

# ----------------------------------------------------------------------------
# Download + size verification
# ----------------------------------------------------------------------------
function Get-RemoteFileSize {
    param([string]$Url)

    $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing
    $raw = $response.Headers['Content-Length']
    if ($raw -is [array]) { $raw = $raw[0] }

    if (-not $raw) {
        throw "The server did not report a Content-Length for $Url, so the download cannot be size-verified."
    }
    return [int64]$raw
}

function Get-InstallerPackage {
    Write-Info "Checking remote file size..."
    $expectedSize = Get-RemoteFileSize -Url $ZipUrl
    Write-Info ("Remote file size: {0:N0} bytes ({1:N1} MB)" -f $expectedSize, ($expectedSize / 1MB))

    for ($attempt = 1; $attempt -le $DownloadRetries; $attempt++) {
        if (Test-Path -LiteralPath $ZipPath) {
            Remove-Item -LiteralPath $ZipPath -Force
        }

        Write-Info "Downloading installer (attempt $attempt of $DownloadRetries). This can take several minutes..."
        try {
            Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
        }
        catch {
            Write-Warn "Download attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $DownloadRetries) { Start-Sleep -Seconds 5 }
            continue
        }

        $actualSize = (Get-Item -LiteralPath $ZipPath).Length
        if ($actualSize -eq $expectedSize) {
            Write-Ok ("Download complete. Size verified: {0:N0} bytes." -f $actualSize)
            return
        }

        Write-Warn ("Size mismatch: expected {0:N0} bytes, got {1:N0} bytes." -f $expectedSize, $actualSize)
        if ($attempt -lt $DownloadRetries) { Start-Sleep -Seconds 5 }
    }

    throw "Installer download failed or did not match the expected size after $DownloadRetries attempts."
}

function Expand-InstallerPackage {
    Write-Info "Extracting installer files to $TempRoot ..."
    Unblock-File -LiteralPath $ZipPath
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $TempRoot -Force

    if (-not (Test-Path -LiteralPath $InstallerFolder)) {
        throw "Installer payload folder was not found after extraction: $InstallerFolder"
    }
    Write-Ok "Extraction complete."
}

# ----------------------------------------------------------------------------
# Install plan (MSI order is critical and must not change)
# ----------------------------------------------------------------------------
function Get-InstallPlan {
    $steps = @(
        @{ Name = 'Document Converter'; MSI = "$InstallerFolder\IRDocumentConverter.64.msi" },
        @{ Name = 'PDF Printer';        MSI = "$InstallerFolder\ImageRight.PDFPrinter.64.msi" },
        @{ Name = 'Desktop Client';     MSI = "$InstallerFolder\IRDesktop.msi" },
        @{ Name = 'Front End';          MSI = "$InstallerFolder\FrontEnd.msi" },
        @{ Name = 'IR Connect';         MSI = "$InstallerFolder\IRConnect.msi" },
        @{ Name = 'Adobe Plugin';       MSI = "$InstallerFolder\IRAdobePlugin.msi" },
        @{ Name = 'Microsoft Addins';   MSI = "$InstallerFolder\IRMicrosoftAddIn.msi" },
        @{ Name = 'Installer Service';  MSI = "$InstallerFolder\IRInstallerService.msi" },
        # 1638 = another version of this product is already installed. Not an error for the launcher,
        # which is not removed by the ImageRight uninstall step.
        @{ Name = 'Benefit Point';      MSI = "$InstallerFolder\Sagitta.Launcher.msi"; ExtraOkCodes = @(1638) },
        @{ Name = 'Browser Plugin';     MSI = "$InstallerFolder\IRBrowserPlugin.msi" }
    )
    return $steps
}

function Get-CopyPlan {
    $steps = @(
        @{ Name = 'IR Desktop Config';           Source = "$InstallerFolder\imageright.desktop.exe.config";    Destination = 'C:\Program Files (x86)\ImageRight\Clients\imageright.desktop.exe.config' },
        @{ Name = 'IR Admin Config';             Source = "$InstallerFolder\imageright.emc.exe.config";        Destination = 'C:\Program Files (x86)\ImageRight\Clients\imageright.emc.exe.config' },
        @{ Name = 'IR Connect Config';           Source = "$InstallerFolder\ImageRight.Connect.exe.config";    Destination = 'C:\Program Files (x86)\ImageRight\IRConnect\ImageRight.Connect.exe.config' },
        @{ Name = 'IR Installer Service Config'; Source = "$InstallerFolder\IRInstallerService.exe.config";    Destination = 'C:\Program Files (x86)\ImageRight\InstallerService\IRInstallerService.exe.config' },
        @{ Name = 'AMS360 Link';                 Source = "$InstallerFolder\AMS360Link.config";                Destination = 'C:\ProgramData\ImageRight\Integration\AMS360Link.config' }
    )
    return $steps
}

function Assert-PayloadComplete {
    $missing = @()
    foreach ($s in (Get-InstallPlan)) { if (-not (Test-Path -LiteralPath $s.MSI))    { $missing += $s.MSI } }
    foreach ($c in (Get-CopyPlan))    { if (-not (Test-Path -LiteralPath $c.Source)) { $missing += $c.Source } }

    if ($missing.Count -gt 0) {
        throw "Installer payload is incomplete. Missing files:`n  $($missing -join "`n  ")"
    }
    Write-Ok "All required MSI and config files are present."
}

# ----------------------------------------------------------------------------
# MSI helper
# ----------------------------------------------------------------------------
function Invoke-MsiStep {
    param(
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$ExtraOkCodes = @()
    )

    $okCodes = @(0, 3010, 1641) + $ExtraOkCodes

    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden

    if ($null -eq $process) {
        throw "$StepName failed: msiexec did not start."
    }

    $code = $process.ExitCode
    if ($code -notin $okCodes) {
        throw "$StepName failed with exit code $code. See logs in $MsiLogFolder"
    }

    if ($code -in 3010, 1641) {
        $script:RebootRequired = $true
        Write-Warn "$StepName completed and requested a reboot ($code)."
    }
    elseif ($code -in $ExtraOkCodes) {
        Write-Warn "$StepName returned exit code $code (treated as success)."
    }
    else {
        Write-Ok "$StepName completed."
    }
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
function Uninstall-ImageRight {
    Write-Info "Searching for existing ImageRight installations..."

    $results = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*ImageRight*' }

    if (-not $results) {
        Write-Info "No existing ImageRight products found."
        return
    }

    $msiProducts = $results | Where-Object { $_.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$' } |
        Sort-Object PSChildName -Unique
    $nonMsi = $results | Where-Object { $_.PSChildName -notmatch '^\{[0-9A-Fa-f\-]{36}\}$' }

    foreach ($item in $nonMsi) {
        Write-Warn "Skipping non-MSI entry '$($item.DisplayName)'. It must be removed manually if required."
    }

    $i = 0
    foreach ($item in $msiProducts) {
        $i++
        $productCode = $item.PSChildName
        $label = "Uninstalling '$($item.DisplayName)' $($item.DisplayVersion) ($i of $(@($msiProducts).Count))"
        Write-Info "$label ..."

        $logFile = Join-Path $MsiLogFolder ("Uninstall_{0}.log" -f ($productCode -replace '[{}]', ''))
        $args = @('/x', "`"$productCode`"", '/qn', '/norestart', "/l*v `"$logFile`"")

        # 1605 = product not installed (stale entry) - treat as OK
        Invoke-MsiStep -StepName "Uninstall $($item.DisplayName)" -Arguments $args -ExtraOkCodes @(1605)
    }
}

# ----------------------------------------------------------------------------
# Install
# ----------------------------------------------------------------------------
function Install-ImageRight {
    $plan  = Get-InstallPlan
    $total = @($plan).Count
    $n     = 0

    foreach ($step in $plan) {
        $n++
        Write-Info "Installing $($step.Name) ($n of $total)..."

        $safeName = $step.Name -replace '[^A-Za-z0-9]', ''
        $logFile  = Join-Path $MsiLogFolder "Install_$safeName.log"
        $args     = @('/i', "`"$($step.MSI)`"", '/quiet', '/norestart', 'ALLUSERS=1', "/l*v `"$logFile`"")

        $extra = @()
        if ($step.ContainsKey('ExtraOkCodes')) { $extra = $step.ExtraOkCodes }

        Invoke-MsiStep -StepName $step.Name -Arguments $args -ExtraOkCodes $extra
    }
}

function Copy-ImageRightConfigs {
    $plan  = Get-CopyPlan
    $total = @($plan).Count
    $n     = 0

    foreach ($item in $plan) {
        $n++
        Write-Info "Copying $($item.Name) ($n of $total)..."

        $destDir = Split-Path -Path $item.Destination -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $item.Source -Destination $item.Destination -Force
    }
    Write-Ok "Config files copied."
}

function Restart-ImageRightService {
    $svc = Get-Service -Name $IRServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warn "Service '$IRServiceName' not found. Verify the service name with Get-Service."
        return
    }
    Write-Info "Restarting service '$IRServiceName'..."
    Restart-Service -Name $IRServiceName -Force
    Write-Ok "Service restarted."
}

# ----------------------------------------------------------------------------
# Permissions
# Vendor requirement (Vertafore): local Users group needs FullControl on the
# ImageRight program folder. Uses the well-known SID for BUILTIN\Users so it
# works on any OS language.
# ----------------------------------------------------------------------------
function Set-IRFolderPermissions {
    if (-not (Test-Path -LiteralPath $IRFolderPath)) {
        throw "ImageRight folder does not exist: $IRFolderPath"
    }

    Write-Info "Granting BUILTIN\Users FullControl on $IRFolderPath (vendor requirement)..."

    $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $acl = Get-Acl -Path $IRFolderPath

    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $usersSid,
        'FullControl',
        'ContainerInherit,ObjectInherit',
        'None',
        'Allow'
    )

    $acl.AddAccessRule($accessRule)
    Set-Acl -Path $IRFolderPath -AclObject $acl
    Write-Ok "Folder permissions applied."
}

# ----------------------------------------------------------------------------
# Browser extensions (disabled by default - see $InstallBrowserExtensions)
# ----------------------------------------------------------------------------
function Add-ExtensionPolicy {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Chrome', 'Edge')][string]$Browser,
        [Parameter(Mandatory = $true)][string]$ExtensionID
    )

    $policyPath = switch ($Browser) {
        'Chrome' { 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' }
        'Edge'   { 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' }
    }

    if (-not (Test-Path -LiteralPath $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }

    $props = (Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue).PSObject.Properties |
        Where-Object { $_.Name -match '^\d+$' }

    $storeUrl = if ($Browser -eq 'Chrome') { 'https://clients2.google.com/service/update2/crx' } else { 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
    $value = "$ExtensionID;$storeUrl"

    if ($props.Value -contains $value) { return }

    $max = ($props | ForEach-Object { [int]$_.Name } | Measure-Object -Maximum).Maximum
    $nextIndex = if ($null -eq $max) { 1 } else { $max + 1 }

    New-ItemProperty -Path $policyPath -Name ([string]$nextIndex) -PropertyType String -Value $value -Force | Out-Null
}

function Install-BrowserExtensions {
    $extensions = @{
        Chrome = @('lmjkddpocmpfpfelefmjeikplccmchaj')
        Edge   = @('bbcadncpbhofkhfbpokeflalmknkfjip')
    }

    foreach ($browser in $extensions.Keys) {
        foreach ($extensionId in $extensions[$browser]) {
            Add-ExtensionPolicy -Browser $browser -ExtensionID $extensionId
        }
    }
}

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------
function Remove-InstallerFiles {
    Set-Location -LiteralPath $TempRoot -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallerFolder -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
$ExitCode = 1
$transcriptStarted = $false

try {
    Write-Step 1 'Pre-checks'
    Initialize-Environment

    try {
        Start-Transcript -Path $TranscriptPath -Force | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Warn "Could not start transcript: $($_.Exception.Message)"
    }

    Stop-RunningApps
    Write-Ok "Pre-checks complete."

    Write-Step 2 'Checking installed version'
    if (Test-ImageRightUpToDate) {
        $ExitCode = 0
    }
    else {
        Write-Step 3 'Downloading installer package'
        Get-InstallerPackage

        Write-Step 4 'Extracting and verifying installer package'
        Expand-InstallerPackage
        Assert-PayloadComplete

        Write-Step 5 'Removing previous ImageRight version'
        Uninstall-ImageRight

        Write-Step 6 'Installing ImageRight components'
        Install-ImageRight

        Write-Step 7 'Applying configuration, service restart, and permissions'
        Copy-ImageRightConfigs
        Restart-ImageRightService
        Set-IRFolderPermissions
        if ($InstallBrowserExtensions) {
            Write-Info "Configuring browser extension policies..."
            Install-BrowserExtensions
        }

        if ($script:RebootRequired) {
            Write-Warn "ImageRight installation complete. A reboot is required (exit code 3010)."
            $ExitCode = 3010
        }
        else {
            Write-Ok "ImageRight installation complete."
            $ExitCode = 0
        }
    }
}
catch {
    Write-Host ""
    Write-Host "Installer execution failed: $($_.Exception.Message)" -ForegroundColor Red
    $ExitCode = 1
}
finally {
    Write-Step 8 'Cleaning up temporary files'
    Remove-InstallerFiles
    Write-Info "MSI logs: $MsiLogFolder"
    Write-Info "Transcript: $TranscriptPath"
    Write-Host ""
    Write-Host ("[{0}] Finished with exit code {1}." -f (Get-Date -Format 'HH:mm:ss'), $ExitCode) -ForegroundColor Cyan

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $ExitCode
