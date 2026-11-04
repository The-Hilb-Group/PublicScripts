#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs / upgrades ImageRight 25R1 (Vertafore) and its companion components.

.DESCRIPTION
    Flow:
      1. Pre-checks (admin, C:\Temp, running apps)
      2. Detect installed version (registry, [version] comparison). If ImageRight is already current,
         steps 3-7 are skipped but patching (step 8) still runs
      3. Reuse an existing installer zip if its SHA-256 matches (e.g., left over from an interrupted run);
         otherwise select download source (office-local server if reachable, otherwise Azure cloud URL),
         download the installer zip (BITS first, Invoke-WebRequest as fallback) and verify its SHA-256 hash
      4. Expand archive and confirm every MSI / config file exists
      5. Uninstall previous ImageRight MSI products and the BenefitPoint launcher, and delete the ImageRight
         program and data folders (only after payload is verified)
      6. Install MSIs in required order (each logged)
      7. Copy configs, restart installer service, apply folder permissions
      8. Apply the latest ImageRight patches (.msp) on every run: discover them on the vendor release notes
         page, check this machine first, then download, install, verify, and clean up only what is needed
      9. Cleanup (always runs)

    Exit codes:  0 = success / already current,  3010 = success, reboot required,  1 = failure
                 Patch failures are logged as warnings and do NOT change the exit code; the base install
                 result decides it (3010 is still returned if a patch requires a reboot).

.PARAMETER SkipPatches
    Skips Step 8 (ImageRight patching). Only the base install/version check runs.

.PARAMETER Silent
    Suppresses all console output. Everything that would have been printed is written to a log file in the
    same folder as the other logs ($MsiLogFolder), named Transcript_ImageRight_<computer>_<timestamp>.log.
    The exit code is unchanged. The log path is not shown on screen; it is recorded near the top of the log.

.PARAMETER ForceUninstall
    TEMPORARY test switch (remove when testing is finished). Uninstalls every installed ImageRight MSI product
    and the BenefitPoint launcher, regardless of the installed version (the version check is bypassed) and then deletes the ImageRight program
    and data folders ($IRFolderPath and $IRDataFolderPath), then exits. Nothing is downloaded, installed, or
    patched. Run the script again without the switch to test a fresh install.
    Exit codes: 0 = uninstalled, 3010 = uninstalled but a reboot is required, 1 = an uninstall failed or a
    folder could not be fully removed.

.EXAMPLE
    .\Install-ImageRight25R1.ps1

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -SkipPatches

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Silent

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -ForceUninstall

.NOTES
    Version      : 1.5.0
    Baseline date: 2026-10-12
    Target       : ImageRight 25R1 (Vertafore)

    Baseline behavior - changes from here should bump the version and be logged below:
      - Download is verified by SHA-256 hash against $ExpectedSha256 (no size comparison against the server).
        A hash mismatch fails that source immediately (no retry). The hash must be updated whenever the
        installer package changes.
        If the hash is missing/invalid the script refuses to download (fails closed).
      - BUILTIN\Users keeps FullControl on 'C:\Program Files (x86)\ImageRight' (Vertafore requirement).
      - Install order of MSIs is critical and must not change.
      - Browser extension policy push is disabled ($InstallBrowserExtensions = $false).
      - The uninstall step (used for upgrades and by -ForceUninstall) also removes the BenefitPoint launcher
        (matched by Add/Remove Programs display name via $UninstallDisplayNamePatterns) and deletes $IRFolderPath and
        $IRDataFolderPath after the MSI uninstalls. Locked files are retried, and a folder that still cannot be
        removed is a warning on upgrades (the install continues) and a failure (exit 1) for -ForceUninstall.
        Config files are re-copied and folder permissions re-applied in step 7 after the reinstall.
      - Up-to-date threshold is $RequiredVersion (25.1.1.204).

    Patching (Step 8):
      - Runs on every execution, after the base install (or on its own when ImageRight is already
        current). Finds the newest patch for each ImageRight component on the vendor release notes page
        ($PatchReleaseNotesUrl) and applies only what is missing on this machine. Patches are no longer
        read from the installer zip.
      - Required components (expected everywhere) log a warning if the base app is missing; optional
        components are skipped quietly when the base app is not installed.
      - Patches are not hash-verified: they come from a known-good vendor source and the vendor page
        publishes no hashes. The .msp is validated by reading its patch metadata before it is applied,
        and every apply is verified against Windows Installer's patch registration afterward.
      - $PatchRegisteredNames maps each patch prefix to the display name Windows registers for it
        (e.g. 'ImageRight Desktop Patch'), so the name note in the console only appears when an .msp
        registers under an unexpected name. The name carries no version, so it is NOT used to skip a
        download; whether a patch is applied is always decided by its patch code.
      - Patch failures are logged as warnings and do not change the exit code. Failed .msp files are kept
        in $PatchDestination for investigation. Use -SkipPatches to skip this step.
      - Patch msiexec logs are written to $MsiLogFolder alongside the base install logs.
      - Patch files are downloaded with the same logic as the installer zip (see "Downloads" below).

    Download source selection:
      - The workstation's office is determined from its IPv4 address (second octet):
            10.1.x.x = St Rose,  10.2.x.x = LaPlace,  10.3.x.x = Lutcher,  10.4.x.x = Mandeville
      - Each office has a local download URL in $OfficeMap (HTTP, SHA-256 verified). An office with a
        blank URL is skipped and uses the cloud URL.
      - If the local source is unreachable, fails to download, or fails SHA-256 verification,
        the script falls back to the Azure cloud URL ($CloudZipUrl).
      - If the office cannot be determined (e.g., remote/VPN/home network), the cloud URL is used.

    Downloads (installer zip and patch files):
      - BITS (Start-BitsTransfer) is tried first, with progress reported to the console. Invoke-WebRequest is
        used only if BITS is not present or the BITS transfer fails.
      - After a BITS failure, BITS is skipped for the rest of the run (this includes the cloud fallback source
        and the patch downloads). The SHA-256 check on the installer zip applies regardless of method.
      - The quick reachability probe for local sources is a small HEAD request and still uses Invoke-WebRequest.

    Silent mode (-Silent):
      - No console output at all. Every line the script would print (including the patching output) is
        appended to $SilentLogPath instead, in the same folder as the msiexec logs ($MsiLogFolder).
      - PowerShell's built-in transcript only records what the console host displays, so it cannot be used
        when the console is suppressed. In silent mode the script therefore writes its own log (same lines,
        same timestamps) and does not start the C:\Temp\Debug.txt transcript. Normal runs are unchanged.
      - Warning, verbose, and information streams are also silenced so nothing leaks to the screen.

    Change log:
      1.0.0  2026-10-12  Initial commit.
      1.1.0  2026-10-13  Added MSP patch step: applies 4 patches from the installer zip, in order, after the
                         main MSIs are installed and before configs are copied. TotalSteps is now 9.
      1.2.0  2026-10-23  Replaced the zip-bundled MSP patch step with dynamic patching (now Step 8): discovers
                         the latest .msp patches on the vendor release notes page, checks the machine first,
                         then downloads (BITS with Invoke-WebRequest fallback), installs, verifies against
                         Windows Installer's patch registration, and cleans up only what is needed. Patching
                         runs on every execution, including when the base install is already current (steps
                         3-7 are skipped in that case). Patch failures are warnings only and do not affect
                         the exit code. Added -SkipPatches. Removed Get-PatchPlan and Install-ImageRightPatches;
                         the payload check no longer requires .msp files in the zip. Configs are now copied
                         before patching (step 7), and cleanup remains step 9.
      1.3.0  2026-10-23  The installer zip now downloads with the same logic as the patches: BITS first, with
                         Invoke-WebRequest only if BITS is not present or fails (Save-FileWithFallback).
      1.3.1  2026-10-23  Added TEMPORARY -ForceUninstall test switch: uninstalls all ImageRight MSI products
                         regardless of version, then exits without installing or patching.
      1.4.0  2026-10-23  The uninstall step now also deletes C:\Program Files (x86)\ImageRight and
                         C:\ProgramData\ImageRight after the MSI uninstalls (upgrades and -ForceUninstall).
                         The installer service is stopped first and locked files are retried.
      1.5.0  2026-11-04  Added -Silent: no console output; all output is written to a log file in the same folder
                         as the other logs. All console writes now go through Write-Console.
#>

[CmdletBinding()]
param(
    [switch]$SkipPatches,

    # Suppress all console output; write it to a log file in $MsiLogFolder instead.
    [switch]$Silent,

    # TEMPORARY: test switch. Uninstalls ImageRight regardless of version, then exits (see .PARAMETER).
    [switch]$ForceUninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
if ($Silent) {
    # Keep every other stream off the console too; output goes to the silent log instead.
    $WarningPreference     = 'SilentlyContinue'
    $VerbosePreference     = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
}

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
$AppDisplayName   = 'ImageRight Desktop'          # Must match DisplayName in Add/Remove Programs exactly
$RequiredVersion  = [version]'25.1.1.204'         # Installed version >= this is treated as up to date
$TempRoot         = 'C:\Temp'
$CloudZipUrl      = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/RIV/25R1-RIV.zip'
$ZipPath          = Join-Path $TempRoot '25R1-RIV.zip'
$InstallerFolder  = Join-Path $TempRoot 'IR25R1'
$MsiLogFolder     = Join-Path $TempRoot 'ImageRightInstallLogs'
$TranscriptPath   = Join-Path $TempRoot 'Debug.txt'
$IRFolderPath     = 'C:\Program Files (x86)\ImageRight'
$IRDataFolderPath = 'C:\ProgramData\ImageRight'
$IRCleanupFolders = @($IRFolderPath, $IRDataFolderPath)   # Deleted after the MSI uninstalls (see Remove-ImageRightFolders)
$FolderRemoveRetries = 3                          # How many times to try deleting a folder with locked files

# Add/Remove Programs display names (wildcards allowed) removed by the uninstall step. The BenefitPoint launcher
# (Sagitta.Launcher.msi in the payload) appears in Programs and Features as 'Sagitta Launcher' and does not have
# 'ImageRight' in its name, so it is matched separately (trailing wildcard allows a version suffix).
$UninstallDisplayNamePatterns = @('*ImageRight*', 'Sagitta Launcher*')
$IRServiceName    = 'ImageRightInstallerService'
$DownloadRetries  = 3
$LocalProbeTimeoutSec = 10                        # How long to wait when checking whether a local source is reachable
$ExpectedSha256   = '773DAD685FB1EC6E280AE0608CCDE2CC9A42A2B73BB7D62A95739CE5C78C3805'   # SHA-256 of 25R1-RIV.zip; update with every package change

# Office map, keyed by the SECOND octet of the workstation's 10.x.x.x address.
# Leave a LocalZipUrl blank to make that office use the cloud URL.
$OfficeMap = @{
    1 = @{ Name = 'St Rose';    LocalZipUrl = 'http://10.1.5.10/25R1-RIV.zip' }
    2 = @{ Name = 'LaPlace';    LocalZipUrl = 'http://10.2.5.10/25R1-RIV.zip' }
    3 = @{ Name = 'Lutcher';    LocalZipUrl = 'http://10.3.5.10/25R1-RIV.zip' }
    4 = @{ Name = 'Mandeville'; LocalZipUrl = 'http://10.4.5.10/25R1-RIV.zip' }
}

# --- BITS (used for the installer zip and patch downloads) ---
$BitsJobName      = 'ImageRight25R1Download'
$BitsNoProgressTimeoutSec = 120                  # Fail the BITS transfer if no bytes move for this long
$BitsReportIntervalSec    = 1                    # How often BITS progress is printed to the console

# --- ImageRight patching (Step 8) ---
$PatchReleaseNotesUrl     = 'https://help.vertafore.com/imagerightbrowserclient/content/releasenotes_25r1.htm'
$PatchDestination         = 'C:\Temp\IR_Patches'
$PatchSkipOptional        = $false               # $true = don't process the optional list at all
$PatchCleanupDelaySeconds = 5                    # Wait before cleanup (and between retries) so file locks can clear
$PatchCleanupRetries      = 3                    # How many times to try deleting a locked file
$RunStamp                 = Get-Date -Format 'yyyyMMdd_HHmmss'
$SilentLogPath            = Join-Path $MsiLogFolder ('Transcript_ImageRight_{0}_{1}.log' -f $env:COMPUTERNAME, $RunStamp)

# Patch prefix -> Programs and Features display name of the base app. Processed in this order.
# Wildcards are allowed in the display name (e.g. 'ImageRight Desktop*').
# Required: expected on every machine. A missing base app is logged as a warning and the patch is skipped.
$PatchRequiredApps = [ordered]@{
    'FrontEnd.Patch'         = 'ImageRight Front End Integration'
    'IRMicrosoftAddIn.Patch' = 'ImageRight Microsoft Add In'
    'IRConnect.Patch'        = 'ImageRight Connect'
    'IRDesktop.Patch'        = 'ImageRight Desktop'
    'IRAdobe.Patch'          = 'ImageRight Adobe Plug-In'
    'IRBrowser.Patch'        = 'ImageRight Browser Plug-in'
}

# Optional: only patched if the base app is installed; skipped quietly if not.
$PatchOptionalApps = [ordered]@{
    'IRWFStudio.Patch' = 'ImageRight Workflow Studio'
    'IRAdmin.Patch'    = 'Imageright Enterprise Management Console'
    'IRScanner.Patch'  = 'ImageRight Scanner'
}

# Patch prefix -> the display name Windows Installer registers for that patch (shown under
# "View installed updates" and read from the .msp's own metadata). Used only to recognise the patch by
# name: the console note about a name mismatch appears only if an .msp registers under a different name.
# The name has no version in it, so it is not used to skip downloads. Prefixes without an entry fall back
# to comparing against the patch file name from the release notes.
$PatchRegisteredNames = @{
    'FrontEnd.Patch'         = 'ImageRight Front End Integration Patch'
    'IRMicrosoftAddIn.Patch' = 'ImageRight Microsoft Add In Patch'
    'IRConnect.Patch'        = 'ImageRight Connect Patch'
    'IRDesktop.Patch'        = 'ImageRight Desktop Patch'
    'IRAdobe.Patch'          = 'ImageRight Adobe Patch'
    'IRBrowser.Patch'        = 'ImageRight Browser Patch'
    'IRWFStudio.Patch'       = 'ImageRight Workflow Studio Patch'
    'IRAdmin.Patch'          = 'ImageRight Enterprise Management Console Patch'
    'IRScanner.Patch'        = 'ImageRight Scanner Patch'
}

# Browser extension push is currently disabled (matches the original script).
# Set to $true to re-enable.
$InstallBrowserExtensions = $false

$script:RebootRequired    = $false
$script:BitsDisabled      = $false               # Set after a BITS failure so remaining downloads use Invoke-WebRequest
$script:TotalSteps        = 9
$script:PatchFailureCount = 0
$script:FolderCleanupOk  = $true

# ----------------------------------------------------------------------------
# Console output helpers
# ----------------------------------------------------------------------------
function Write-Console {
    # Single point for all console output. Normally prints to the screen. With -Silent nothing is printed;
    # the line is appended to $SilentLogPath instead. Logging problems never stop the install.
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Message = '',
        [string]$ForegroundColor
    )

    if (-not $Silent) {
        if ($ForegroundColor) { Write-Host $Message -ForegroundColor $ForegroundColor }
        else                  { Write-Host $Message }
        return
    }

    try {
        $dir = Split-Path -Path $SilentLogPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $SilentLogPath -Value $Message -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

function Write-Step {
    param([int]$Number, [string]$Message)
    Write-Console ""
    Write-Console ("[{0}] [Step {1}/{2}] {3}" -f (Get-Date -Format 'HH:mm:ss'), $Number, $script:TotalSteps, $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Console ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Write-Ok {
    param([string]$Message)
    Write-Console ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Console ("[{0}]     WARNING: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Yellow
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
        Write-Ok "'$AppDisplayName' version $installed is already at or above required version $RequiredVersion. Base install not needed."
        return $true
    }

    Write-Info "'$AppDisplayName' version $installed is older than required $RequiredVersion. Proceeding with upgrade."
    return $false
}

# ----------------------------------------------------------------------------
# Office detection (by assigned IPv4 address)
# ----------------------------------------------------------------------------
function Get-WorkstationIPv4Addresses {
    # Prefer adapters that are Up and have a default gateway (the "real" network connection).
    # This reduces the chance of matching a virtual/VM/VPN adapter.
    $ips = @()

    try {
        $configs = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address }
        $ips = @($configs | ForEach-Object { $_.IPv4Address.IPAddress })
    }
    catch {
        Write-Warn "Get-NetIPConfiguration failed: $($_.Exception.Message)"
    }

    if ($ips.Count -eq 0) {
        # Fallback: any non-loopback, non-APIPA IPv4 address
        try {
            $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                ForEach-Object { $_.IPAddress })
        }
        catch {
            Write-Warn "Get-NetIPAddress failed: $($_.Exception.Message)"
        }
    }

    return $ips
}

function Get-WorkstationOffice {
    # Returns @{ Name; IP; LocalZipUrl } for the first IP that maps to a known office, or $null.
    $ips = Get-WorkstationIPv4Addresses

    if (@($ips).Count -eq 0) {
        Write-Info "No usable IPv4 address found. Office cannot be determined."
        return $null
    }

    Write-Info "Detected IPv4 address(es): $($ips -join ', ')"

    foreach ($ip in $ips) {
        if ($ip -match '^10\.(\d{1,3})\.\d{1,3}\.\d{1,3}$') {
            $octet = [int]$Matches[1]
            if ($OfficeMap.ContainsKey($octet)) {
                $office = $OfficeMap[$octet]
                return @{ Name = $office.Name; IP = $ip; LocalZipUrl = $office.LocalZipUrl }
            }
        }
    }

    Write-Info "IP address(es) do not match a known office subnet."
    return $null
}

# ----------------------------------------------------------------------------
# Download source selection
# ----------------------------------------------------------------------------
function Get-DownloadSources {
    # Builds an ordered list of sources: local (if available) first, cloud always last.
    $sources = @()

    $office = Get-WorkstationOffice
    if ($office) {
        Write-Info "Workstation office: $($office.Name) (IP $($office.IP))"

        if ([string]::IsNullOrWhiteSpace($office.LocalZipUrl)) {
            Write-Info "No local download URL configured for $($office.Name). Using cloud source."
        }
        else {
            Write-Info "Checking whether local source is reachable: $($office.LocalZipUrl)"
            try {
                Test-SourceReachable -Url $office.LocalZipUrl -TimeoutSec $LocalProbeTimeoutSec
                Write-Ok "Local source for $($office.Name) is reachable."
                $sources += @{ Label = "Local ($($office.Name))"; Url = $office.LocalZipUrl }
            }
            catch {
                Write-Warn "Local source for $($office.Name) is not available: $($_.Exception.Message)"
                Write-Info "Falling back to cloud source."
            }
        }
    }
    else {
        Write-Info "Office not determined. Using cloud source."
    }

    $sources += @{ Label = 'Cloud (Azure)'; Url = $CloudZipUrl }
    return $sources
}

# ----------------------------------------------------------------------------
# Download + SHA-256 verification
# ----------------------------------------------------------------------------
function Test-SourceReachable {
    # Quick HEAD request. Throws if the server does not answer successfully within the timeout.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 30
    )

    $null = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec
}

function Save-InstallerFromSource {
    # Tries to download and hash-verify the zip from a single source. Returns $true on success, $false on failure.
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Url
    )

    Write-Info "Source: $Label"

    for ($attempt = 1; $attempt -le $DownloadRetries; $attempt++) {
        if (Test-Path -LiteralPath $ZipPath) {
            Remove-Item -LiteralPath $ZipPath -Force
        }

        Write-Info "Downloading installer from $Label (attempt $attempt of $DownloadRetries). This can take several minutes..."
        try {
            Save-FileWithFallback -Url $Url -Destination $ZipPath
        }
        catch {
            Write-Warn "Download attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $DownloadRetries) { Start-Sleep -Seconds 5 }
            continue
        }

        $size = (Get-Item -LiteralPath $ZipPath).Length
        Write-Info ("Download complete ({0:N0} bytes, {1:N1} MB). Verifying SHA-256 hash..." -f $size, ($size / 1MB))

        $actualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        if ($actualHash -ieq $ExpectedSha256) {
            Write-Ok "Download from $Label verified (SHA-256 match)."
            return $true
        }

        # A hash mismatch is not retried: discard the file and fail this source immediately so the
        # caller can move on to the next one (local -> cloud).
        Write-Warn "SHA-256 mismatch from $Label. Expected $ExpectedSha256 but got $actualHash. Discarding download."
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Leave nothing partial behind before the next source is tried
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    }
    Write-Warn "Download from $Label failed after $DownloadRetries attempts."
    return $false
}

function Test-ExistingInstallerPackage {
    # Returns $true if a zip from a previous run (e.g., interrupted by another installation) is present
    # and its SHA-256 matches $ExpectedSha256. Otherwise removes it (if present) and returns $false.
    # The SHA-256 check alone is sufficient; no size comparison is needed.
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        Write-Info "No existing installer zip found. A download is required."
        return $false
    }

    Write-Info "Existing installer zip found at $ZipPath. Verifying it..."

    try {
        $size = (Get-Item -LiteralPath $ZipPath).Length
        $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    }
    catch {
        Write-Warn "Could not read the existing zip: $($_.Exception.Message). It will be re-downloaded."
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    if ($hash -ieq $ExpectedSha256) {
        Write-Ok ("Existing zip is valid ({0:N0} bytes, SHA-256 verified). Skipping download." -f $size)
        return $true
    }

    Write-Warn ("Existing zip failed verification ({0:N0} bytes, SHA-256 {1}). Deleting and re-downloading." -f $size, $hash)
    Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
    return $false
}

function Get-InstallerPackage {
    if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "ExpectedSha256 is missing or is not a valid 64-character SHA-256 value. Refusing to download an unverifiable package."
    }

    # Reuse a verified leftover zip instead of downloading again
    if (Test-ExistingInstallerPackage) {
        return
    }

    $sources = Get-DownloadSources

    foreach ($source in $sources) {
        if (Save-InstallerFromSource -Label $source.Label -Url $source.Url) {
            return
        }
        if ($source -ne $sources[-1]) {
            Write-Info "Trying next download source..."
        }
    }

    throw "Installer download failed from all available sources."
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
# Folder cleanup (leftovers after the MSI uninstalls)
# ----------------------------------------------------------------------------
function Remove-ImageRightFolders {
    # Deletes the folders in $IRCleanupFolders. Stops the installer service first so it does not hold files open,
    # and retries locked files. Returns $true if every folder is gone (or never existed), $false otherwise.
    $allRemoved = $true

    $svc = Get-Service -Name $IRServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Info "Stopping service '$IRServiceName' before removing folders..."
        Stop-Service -Name $IRServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    foreach ($path in $IRCleanupFolders) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Info "Folder not present, nothing to remove: $path"
            continue
        }

        Write-Info "Removing folder $path ..."
        for ($attempt = 1; $attempt -le $FolderRemoveRetries; $attempt++) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warn "Removing $path (attempt $attempt of $FolderRemoveRetries): $($_.Exception.Message)"
                if ($attempt -lt $FolderRemoveRetries) { Start-Sleep -Seconds 3 }
            }

            if (-not (Test-Path -LiteralPath $path)) { break }
        }

        if (Test-Path -LiteralPath $path) {
            Write-Warn "Could not fully remove $path. Remaining files may need to be deleted manually."
            $allRemoved = $false
        }
        else {
            Write-Ok "Removed $path"
        }
    }

    return $allRemoved
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
function Uninstall-ImageRight {
    Write-Info "Searching for existing ImageRight products and the BenefitPoint launcher..."

    $results = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.DisplayName
            $name -and (@($UninstallDisplayNamePatterns | Where-Object { $name -like $_ }).Count -gt 0)
        }

    if (-not $results) {
        Write-Info "No existing ImageRight products or BenefitPoint launcher found."
        $script:FolderCleanupOk = Remove-ImageRightFolders
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
        $msiArgs = @('/x', "`"$productCode`"", '/qn', '/norestart', "/l*v `"$logFile`"")

        # 1605 = product not installed (stale entry) - treat as OK
        Invoke-MsiStep -StepName "Uninstall $($item.DisplayName)" -Arguments $msiArgs -ExtraOkCodes @(1605)
    }

    # Remove what the MSI uninstalls leave behind (program and data folders)
    $script:FolderCleanupOk = Remove-ImageRightFolders
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
        $msiArgs  = @('/i', "`"$($step.MSI)`"", '/quiet', '/norestart', 'ALLUSERS=1', "/l*v `"$logFile`"")

        $extra = @()
        if ($step.ContainsKey('ExtraOkCodes')) { $extra = $step.ExtraOkCodes }

        Invoke-MsiStep -StepName $step.Name -Arguments $msiArgs -ExtraOkCodes $extra
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
# Downloads: installer zip and patch files (BITS first, Invoke-WebRequest fallback)
# ----------------------------------------------------------------------------
function Start-BitsDownload {
    # Downloads a file with BITS as an asynchronous job that is polled so progress can be shown.
    # Throws on any failure so the caller can fall back to Invoke-WebRequest.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        throw "Start-BitsTransfer is not available on this system."
    }
    Import-Module BitsTransfer -ErrorAction Stop

    # Clear any stale job with the same name (e.g., left behind by an interrupted run)
    Get-BitsTransfer -Name $BitsJobName -AllUsers -ErrorAction SilentlyContinue |
        Remove-BitsTransfer -ErrorAction SilentlyContinue

    $job       = $null
    $completed = $false

    try {
        $job = Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName $BitsJobName `
            -Priority Foreground -Asynchronous -ErrorAction Stop

        $lastBytes    = [uint64]0
        $lastProgress = Get-Date
        $lastReport   = Get-Date '2000-01-01'

        while ($true) {
            $job   = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
            $state = [string]$job.JobState
            $now   = Get-Date

            if ($state -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                $completed = $true
                if (-not (Test-Path -LiteralPath $Destination)) {
                    throw "BITS reported success but the file was not found at $Destination."
                }
                return
            }

            if ($state -in 'Error', 'Cancelled') {
                $desc = ''
                try { $desc = $job.ErrorDescription } catch { }
                throw "BITS job ended in state '$state'. $desc"
            }

            if ($state -eq 'Suspended') {
                Resume-BitsTransfer -BitsJob $job -Asynchronous | Out-Null
            }

            # Stall detection
            $bytes = [uint64]$job.BytesTransferred
            if ($bytes -ne $lastBytes) {
                $lastBytes    = $bytes
                $lastProgress = $now
            }
            elseif (($now - $lastProgress).TotalSeconds -gt $BitsNoProgressTimeoutSec) {
                throw "BITS made no progress for $BitsNoProgressTimeoutSec seconds (state: $state)."
            }

            # Periodic console progress
            if (($now - $lastReport).TotalSeconds -ge $BitsReportIntervalSec) {
                $lastReport = $now
                $total = [double]$job.BytesTotal
                if ($total -gt 0 -and $total -lt [double][uint64]::MaxValue) {
                    Write-Info ("BITS {0}: {1:N1} of {2:N1} MB ({3:N0}%)" -f $state, ($bytes / 1MB), ($total / 1MB), (100 * $bytes / $total))
                }
                else {
                    Write-Info ("BITS {0}: {1:N1} MB downloaded" -f $state, ($bytes / 1MB))
                }
            }

            Start-Sleep -Seconds 2
        }
    }
    finally {
        if (-not $completed -and $job) {
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
        }
    }
}

function Save-FileWithFallback {
    # Downloads a file using BITS first; falls back to Invoke-WebRequest if BITS is unavailable or fails.
    # Throws only if the Invoke-WebRequest fallback also fails (the caller handles retries).
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not $script:BitsDisabled) {
        try {
            Write-Info "Download method: BITS"
            Start-BitsDownload -Url $Url -Destination $Destination
            Write-Ok "BITS transfer complete."
            return
        }
        catch {
            Write-Warn "BITS download failed: $($_.Exception.Message)"
            $script:BitsDisabled = $true
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            Write-Info "Falling back to Invoke-WebRequest..."
        }
    }
    else {
        Write-Info "BITS was unavailable earlier in this run. Using Invoke-WebRequest."
    }

    Write-Info "Download method: Invoke-WebRequest"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    Write-Ok "Invoke-WebRequest download complete."
}

# ----------------------------------------------------------------------------
# ImageRight patching (Step 8)
# Finds the latest .msp patches on the vendor release notes page, checks this machine first, then
# downloads, installs, verifies, and cleans up only what is actually needed.
# ----------------------------------------------------------------------------
function Write-PatchLog {
    # Maps the patch logic's log levels onto the script's console helpers (the transcript captures it all).
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'SKIP')][string]$Level = 'INFO'
    )

    if ([string]::IsNullOrEmpty($Message)) {
        Write-Console ""
        return
    }

    switch ($Level) {
        'SUCCESS' { Write-Ok $Message }
        'WARN'    { Write-Warn $Message }
        'ERROR'   { Write-Console ("[{0}]     ERROR: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red }
        'SKIP'    { Write-Console ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor DarkGray }
        default   { Write-Info $Message }
    }
}

function Get-NaturalSortKey {
    param([string]$Value)
    # Pad every run of digits so string sorting = numeric sorting ("10" > "9")
    [regex]::Replace($Value, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}

function ConvertTo-PlainText {
    param([string]$Html)
    [System.Web.HttpUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' '))
}

function Get-InstalledApplication {
    # Every entry from Programs and Features (64-bit, 32-bit, and per-user uninstall keys).
    # Reads the registry directly instead of Win32_Product, which is slow and can trigger MSI repairs.
    Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, PSPath
}

function Test-AppInstalled {
    # Returns the matching Programs and Features entry (or $null) for a display name.
    # Matching is case-insensitive; wildcards are supported.
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [object[]]$InstalledApps = (Get-InstalledApplication)
    )

    $InstalledApps |
        Where-Object { $_.DisplayName -like $DisplayName } |
        Select-Object -First 1
}

function Get-RegisteredPatch {
    # Lists every patch Windows Installer has registered per-machine, with its display name and state
    # (1 = Applied, 2 = Superseded, 4 = Obsoleted). These are the entries shown under "View installed updates".
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\*\Patches\*'

    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DisplayName = $props.DisplayName
            State       = $props.State
            PackedPatch = $_.PSChildName
        }
    } | Where-Object { $_.DisplayName }
}

function Find-RegisteredPatchByName {
    # Looks for an Applied or Superseded patch whose display name contains the patch name from the
    # release notes, so the download can be skipped when Windows already has it.
    param(
        [Parameter(Mandatory = $true)][string]$PatchName,
        [object[]]$RegisteredPatches
    )

    $name = $PatchName -replace '\.msp$', ''
    $RegisteredPatches |
        Where-Object { $_.State -in 1, 2 -and $_.DisplayName -like "*$name*" } |
        Select-Object -First 1
}

function Invoke-ComMember {
    # Late-bound COM call; the WindowsInstaller object needs this in Windows PowerShell 5.1.
    param($Object, [string]$Name, [System.Reflection.BindingFlags]$Kind, [object[]]$Arguments = @())
    $Object.GetType().InvokeMember($Name, $Kind, $null, $Object, $Arguments)
}

function ConvertTo-CompressedGuid {
    # Converts {GUID} to the "packed" form Windows Installer uses for registry key names.
    param([Parameter(Mandatory = $true)][string]$Guid)

    $g = $Guid.Trim('{}').Replace('-', '').ToUpper()
    $reverse = { param($s) -join ($s.ToCharArray()[($s.Length - 1)..0]) }

    $packed = (& $reverse $g.Substring(0, 8)) + (& $reverse $g.Substring(8, 4)) + (& $reverse $g.Substring(12, 4))
    for ($i = 16; $i -lt 32; $i += 2) {
        # Cast to string so this is concatenation, not char arithmetic
        $packed += ([string]$g[$i + 1]) + ([string]$g[$i])
    }
    $packed
}

function Get-MspInfo {
    # Reads an .msp file and returns:
    #   PatchCode      - GUID Windows uses to track the patch
    #   TargetProducts - ProductCodes the patch can be applied to
    #   DisplayName    - friendly name from the patch metadata (if present)
    param([Parameter(Mandatory = $true)][string]$Path)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $summary = $db = $view = $record = $null
    try {
        $summary = Invoke-ComMember $installer 'SummaryInformation' 'GetProperty' @($Path, 0)

        # Property 9 (Revision Number): patch code, followed by any codes it obsoletes
        $revision = [string](Invoke-ComMember $summary 'Property' 'GetProperty' @(9))
        if ($revision.Length -lt 38) { throw "No patch code found in $Path" }
        $patchCode = $revision.Substring(0, 38)

        # Property 7 (Template): semicolon-separated list of target ProductCodes
        $template = [string](Invoke-ComMember $summary 'Property' 'GetProperty' @(7))
        $targets  = @($template -split ';' | Where-Object { $_ -match '^\{[0-9A-Fa-f\-]{36}\}$' })

        # Friendly name from the MsiPatchMetadata table (optional - not every patch has it)
        $displayName = $null
        try {
            $db     = Invoke-ComMember $installer 'OpenDatabase' 'InvokeMethod' @($Path, 32)  # 32 = open as patch file
            $query  = "SELECT ``Value`` FROM ``MsiPatchMetadata`` WHERE ``Property``='DisplayName'"
            $view   = Invoke-ComMember $db 'OpenView' 'InvokeMethod' @($query)
            Invoke-ComMember $view 'Execute' 'InvokeMethod' | Out-Null
            $record = Invoke-ComMember $view 'Fetch' 'InvokeMethod'
            if ($record) { $displayName = Invoke-ComMember $record 'StringData' 'GetProperty' @(1) }
        }
        catch { Write-Verbose "No MsiPatchMetadata DisplayName in $Path" }

        [pscustomobject]@{
            PatchCode      = $patchCode
            TargetProducts = $targets
            DisplayName    = $displayName
        }
    }
    finally {
        # Release every COM object that touched the file, otherwise Windows Installer
        # can keep a handle open on the .msp and block cleanup later
        if ($view) { try { Invoke-ComMember $view 'Close' 'InvokeMethod' | Out-Null } catch { } }
        foreach ($com in @($record, $view, $db, $summary, $installer)) {
            if ($com) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) }
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-InstalledTargetProduct {
    # Returns the target ProductCodes that are installed per-machine on this computer.
    param([string[]]$ProductCodes)

    foreach ($code in $ProductCodes) {
        $packed = ConvertTo-CompressedGuid $code
        if (Test-Path "HKLM:\SOFTWARE\Classes\Installer\Products\$packed") { $code }
    }
}

function Get-MspInstallState {
    # Checks Windows Installer's registration of a patch against each installed target product.
    # State values: 1 = Applied, 2 = Superseded, 4 = Obsoleted. Returns one object per installed target product.
    param(
        [Parameter(Mandatory = $true)][string]$PatchCode,
        [string[]]$InstalledProducts
    )

    $packedPatch = ConvertTo-CompressedGuid $PatchCode
    $userData    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18'

    foreach ($product in $InstalledProducts) {
        $packedProduct = ConvertTo-CompressedGuid $product
        $key = "$userData\Products\$packedProduct\Patches\$packedPatch"

        if (Test-Path $key) {
            $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            $state = switch ($props.State) {
                1       { 'Applied' }
                2       { 'Superseded' }
                4       { 'Obsoleted' }
                default { "Unknown ($($props.State))" }
            }
            [pscustomobject]@{ ProductCode = $product; Registered = $true; State = $state; DisplayName = $props.DisplayName }
        }
        else {
            [pscustomobject]@{ ProductCode = $product; Registered = $false; State = 'Not registered'; DisplayName = $null }
        }
    }
}

function Test-MspApplied {
    # $true if the patch is Applied (or Superseded by a newer one) on every installed target product.
    param([object[]]$States)
    [bool]($States -and -not ($States | Where-Object { $_.State -notin 'Applied', 'Superseded' }))
}

function Install-ImageRightPatch {
    # Applies one .msp silently with a verbose msiexec log. Returns the exit code.
    param(
        [Parameter(Mandatory = $true)][string]$MspPath,
        [Parameter(Mandatory = $true)][string]$LogDirectory
    )

    $baseName  = [IO.Path]::GetFileNameWithoutExtension($MspPath)
    $msiLog    = Join-Path $LogDirectory "Patch_${baseName}_$RunStamp.msi.log"
    $arguments = "/p `"$MspPath`" /qn /norestart /l*v `"$msiLog`""

    Write-PatchLog "  Running: msiexec.exe $arguments"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Write-PatchLog "  msiexec log: $msiLog"
    return $process.ExitCode
}

function Get-InstallOutcome {
    # Translates common msiexec exit codes.
    param([int]$ExitCode)
    switch ($ExitCode) {
        0       { 'Installed' }
        3010    { 'Installed (reboot required)' }
        1641    { 'Installed (reboot initiated)' }
        1642    { 'Not applicable' }                        # target product/version not found
        1618    { 'Failed (another install in progress)' }
        1603    { 'Failed (fatal error - see msiexec log)' }
        default { "Failed (exit $ExitCode)" }
    }
}

function Remove-PatchFile {
    # Deletes downloaded .msp files for patches that installed successfully, were already installed, or
    # don't apply to this machine. Failed patches are kept so they can be investigated.
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$DownloadFolder,
        [int]$Retries = 3,
        [int]$DelaySeconds = 5
    )

    $removable = 'Already installed', 'Not applicable'

    foreach ($r in $Results) {
        if ($r.Install -notlike 'Installed*' -and $r.Install -notin $removable) { continue }
        if (-not $r.Path -or -not (Test-Path -LiteralPath $r.Path)) { continue }

        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            try {
                Remove-Item -LiteralPath $r.Path -Force -ErrorAction Stop
                Write-PatchLog "  Removed $($r.Path)"
                $r.Cleanup = 'Removed'
                break
            }
            catch {
                if ($attempt -lt $Retries) {
                    Write-PatchLog "  $($r.Path) is locked (attempt $attempt of $Retries) - waiting $DelaySeconds seconds." -Level SKIP
                    Start-Sleep -Seconds $DelaySeconds
                }
                else {
                    Write-PatchLog "  Could not remove $($r.Path) after $Retries attempts: $($_.Exception.Message)" -Level WARN
                    $r.Cleanup = 'Failed (locked)'
                }
            }
        }
    }

    # Remove the download folder itself if nothing is left in it
    if ((Test-Path -LiteralPath $DownloadFolder) -and -not (Get-ChildItem -LiteralPath $DownloadFolder -Force)) {
        Remove-Item -LiteralPath $DownloadFolder -Force
        Write-PatchLog "  Removed empty folder $DownloadFolder"
    }
}

function Invoke-ImageRightPatching {
    # Runs the full patch flow. Sets $script:PatchFailureCount (and $script:RebootRequired if needed).
    # Produces no pipeline output.
    Add-Type -AssemblyName System.Web
    $script:PatchFailureCount = 0

    # --- Build the work list (blank entries ignored) --------------------------
    $workList = @()
    foreach ($key in $PatchRequiredApps.Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $workList += [pscustomobject]@{ Prefix = $key; Category = 'Required'; BaseApp = $PatchRequiredApps[$key] }
    }
    if (-not $PatchSkipOptional) {
        foreach ($key in $PatchOptionalApps.Keys) {
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $workList += [pscustomobject]@{ Prefix = $key; Category = 'Optional'; BaseApp = $PatchOptionalApps[$key] }
        }
    }

    # Snapshot this machine once (after the base install): installed apps and registered patches
    $installedApps     = @(Get-InstalledApplication)
    $registeredPatches = @(Get-RegisteredPatch)
    Write-Verbose "Found $($installedApps.Count) apps and $($registeredPatches.Count) registered patches."

    # --- Read the release notes page ------------------------------------------
    try {
        $response = Invoke-WebRequest -Uri $PatchReleaseNotesUrl -UseBasicParsing -ErrorAction Stop
        Write-PatchLog "Downloaded release notes: $PatchReleaseNotesUrl"
    }
    catch {
        Write-PatchLog "Failed to download $PatchReleaseNotesUrl : $($_.Exception.Message)" -Level ERROR
        $script:PatchFailureCount = 1
        return
    }

    $pageText = ConvertTo-PlainText $response.Content
    $baseUri  = [Uri]$PatchReleaseNotesUrl

    # Every link on the page with its absolute URL, file name, and visible text
    $links = foreach ($link in $response.Links) {
        if (-not $link.href -or $link.href -match '^(#|mailto:|javascript:)') { continue }
        try   { $absolute = [Uri]::new($baseUri, [System.Web.HttpUtility]::HtmlDecode($link.href)) }
        catch { continue }

        [pscustomobject]@{
            Url      = $absolute.AbsoluteUri
            FileName = [Uri]::UnescapeDataString([IO.Path]::GetFileName($absolute.AbsolutePath))
            Text     = (ConvertTo-PlainText $link.outerHTML).Trim()
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()

    # --- Discover latest patches and check this machine -----------------------
    $currentCategory = $null
    foreach ($item in $workList) {
        $prefix = $item.Prefix

        if ($item.Category -ne $currentCategory) {
            $currentCategory = $item.Category
            Write-PatchLog ''
            Write-PatchLog "=== Checking $currentCategory patches ==="
        }

        $r = [pscustomobject]@{
            Category       = $item.Category
            Prefix         = $prefix
            BaseApp        = $item.BaseApp
            BaseInstalled  = $false
            BaseVersion    = $null
            Latest         = $null
            Url            = $null
            Path           = $null
            Check          = $null
            Download       = $null
            PatchCode      = $null
            TargetProducts = $null
            ExitCode       = $null
            Install        = $null
            Verified       = $null
            Cleanup        = $null
        }
        $results.Add($r)

        # Latest patch name on the page
        $pattern = '(?i)\b' + [regex]::Escape($prefix) + '[\w.\-]*'
        $textMatches = [regex]::Matches($pageText, $pattern) |
            ForEach-Object { $_.Value.TrimEnd('.', '-', '_') } |
            Sort-Object -Unique

        $r.Latest = $textMatches |
            Sort-Object { Get-NaturalSortKey $_ } -Descending |
            Select-Object -First 1

        if (-not $r.Latest) {
            Write-PatchLog ("{0,-25} : no matches found on page" -f "$prefix*") -Level WARN
            $r.Check = 'Not found on page'
            continue
        }
        Write-PatchLog ("{0,-25} : latest is {1}" -f "$prefix*", $r.Latest)
        Write-Verbose ("  All text matches: " + ($textMatches -join ', '))

        # Base app present?
        $app = Test-AppInstalled -DisplayName $item.BaseApp -InstalledApps $installedApps
        if ($app) {
            $r.BaseInstalled = $true
            $r.BaseVersion   = $app.DisplayVersion
            Write-Verbose "  Base app found: $($app.DisplayName) $($app.DisplayVersion)"
        }
        elseif ($item.Category -eq 'Required') {
            Write-PatchLog "  Required base app '$($item.BaseApp)' is NOT installed - skipping this patch." -Level WARN
            $r.Check = 'Base app missing'
            continue
        }
        else {
            Write-PatchLog "  '$($item.BaseApp)' not installed - skipping." -Level SKIP
            $r.Check = 'Base app not installed'
            continue
        }

        # Already installed? (matched by name against Windows' registered patches)
        $existing = Find-RegisteredPatchByName -PatchName $r.Latest -RegisteredPatches $registeredPatches
        if ($existing) {
            Write-PatchLog "  Already installed: '$($existing.DisplayName)' - no download needed." -Level SKIP
            $r.Check    = 'Already installed'
            $r.Install  = 'Already installed'
            $r.Verified = $true
            continue
        }

        # Find the .msp download link for that name
        $candidateLinks = $links | Where-Object {
            $_.FileName -like '*.msp' -and ($_.FileName -match $pattern -or $_.Text -match $pattern)
        }
        Write-Verbose ("  Candidate .msp links: " + (($candidateLinks.Url) -join ', '))

        $link = $candidateLinks |
            Where-Object { $_.FileName -like "$($r.Latest)*" -or $_.Text -like "*$($r.Latest)*" } |
            Select-Object -First 1

        if (-not $link) {
            Write-PatchLog "  No .msp download link found on the page for $($r.Latest)." -Level WARN
            $r.Check = 'No link'
            continue
        }

        $r.Url   = $link.Url
        $r.Path  = Join-Path $PatchDestination $link.FileName
        $r.Check = 'Needed'
        Write-PatchLog "  Needed - will download $($link.FileName)" -Level SUCCESS
    }

    # --- Download what's needed -----------------------------------------------
    $toDownload = @($results | Where-Object { $_.Check -eq 'Needed' })

    Write-PatchLog ''
    Write-PatchLog '=== Downloading patches ==='

    if (-not $toDownload) {
        Write-PatchLog 'Nothing to download - this machine is up to date.' -Level SUCCESS
    }
    else {
        if (-not (Test-Path -LiteralPath $PatchDestination)) {
            New-Item -Path $PatchDestination -ItemType Directory -Force | Out-Null
        }

        foreach ($r in $toDownload) {
            $fileName = Split-Path $r.Path -Leaf

            # Always fetch a fresh copy; a leftover file may be partial or stale
            if (Test-Path -LiteralPath $r.Path) {
                Remove-Item -LiteralPath $r.Path -Force -ErrorAction SilentlyContinue
            }

            Write-PatchLog "$fileName : downloading $($r.Url)"
            try {
                Save-FileWithFallback -Url $r.Url -Destination $r.Path

                if (-not (Test-Path -LiteralPath $r.Path) -or (Get-Item -LiteralPath $r.Path).Length -le 0) {
                    throw "Downloaded file is missing or empty."
                }
                Write-PatchLog "  Saved to $($r.Path)" -Level SUCCESS
                $r.Download = 'Downloaded'
            }
            catch {
                Write-PatchLog "  Download failed for $fileName : $($_.Exception.Message)" -Level ERROR
                $r.Download = 'Failed'
            }
        }
    }

    # --- Install, verify, clean up --------------------------------------------
    $toInstall = @($results | Where-Object { $_.Check -eq 'Needed' -and $_.Download -eq 'Downloaded' })

    if (-not $toInstall) {
        Write-PatchLog ''
        Write-PatchLog 'Nothing to install.'
    }
    else {
        # Final check by patch code, then install (required first, then optional)
        Write-PatchLog ''
        Write-PatchLog '=== Installing patches ==='

        foreach ($r in $toInstall) {
            Write-PatchLog "$($r.Latest)"
            try {
                $info        = Get-MspInfo -Path $r.Path
                $r.PatchCode = $info.PatchCode
                Write-PatchLog "  Patch code: $($info.PatchCode)"
                if ($info.DisplayName) {
                    Write-PatchLog "  Registers in Windows as: $($info.DisplayName)"

                    $expectedName = $null
                    if ($PatchRegisteredNames.ContainsKey($r.Prefix)) { $expectedName = $PatchRegisteredNames[$r.Prefix] }

                    if ($expectedName) {
                        if ($info.DisplayName -notlike "*$expectedName*") {
                            Write-PatchLog "  Note: registered name '$($info.DisplayName)' does not match the mapped name '$expectedName' for $($r.Prefix). Update `$PatchRegisteredNames if Windows lists this patch differently." -Level WARN
                        }
                    }
                    elseif ($info.DisplayName -notlike "*$($r.Latest -replace '\.msp$', '')*") {
                        Write-PatchLog "  Note: this name doesn't contain '$($r.Latest)' and no name mapping exists for $($r.Prefix), so the pre-download name check can't detect it." -Level WARN
                    }
                }

                # Only apply if at least one target product is installed
                $r.TargetProducts = @(Get-InstalledTargetProduct -ProductCodes $info.TargetProducts)
                if (-not $r.TargetProducts) {
                    Write-PatchLog '  None of the products this patch targets are installed - skipping.' -Level WARN
                    $r.Install = 'Not applicable'
                    continue
                }
                Write-PatchLog "  Target product(s) installed: $($r.TargetProducts -join ', ')"

                # Backstop: catches patches whose registered name didn't match by name
                $states = @(Get-MspInstallState -PatchCode $r.PatchCode -InstalledProducts $r.TargetProducts)
                if (Test-MspApplied $states) {
                    Write-PatchLog "  Already applied ($(($states.State | Sort-Object -Unique) -join ', ')) - skipping." -Level SKIP
                    $r.Install  = 'Already installed'
                    $r.Verified = $true
                    continue
                }

                $r.ExitCode = Install-ImageRightPatch -MspPath $r.Path -LogDirectory $MsiLogFolder
                $r.Install  = Get-InstallOutcome $r.ExitCode
                if ($r.ExitCode -in 3010, 1641) { $script:RebootRequired = $true }

                $level = if ($r.Install -like 'Installed*') { 'SUCCESS' } elseif ($r.Install -eq 'Not applicable') { 'WARN' } else { 'ERROR' }
                Write-PatchLog "  Result: $($r.Install) (exit code $($r.ExitCode))" -Level $level
            }
            catch {
                Write-PatchLog "  Install error: $($_.Exception.Message)" -Level ERROR
                $r.Install = 'Failed (error)'
            }
        }

        # Verify against Windows Installer's patch registration
        Write-PatchLog ''
        Write-PatchLog '=== Verifying patches ==='

        foreach ($r in $toInstall) {
            if ($r.Install -notlike 'Installed*') { continue }

            $states     = @(Get-MspInstallState -PatchCode $r.PatchCode -InstalledProducts $r.TargetProducts)
            $r.Verified = Test-MspApplied $states

            foreach ($st in $states) {
                $level = if ($st.State -in 'Applied', 'Superseded') { 'SUCCESS' } else { 'ERROR' }
                Write-PatchLog "$($r.Latest) on $($st.ProductCode): $($st.State)" -Level $level
            }
        }

        # Clean up
        Write-PatchLog ''
        Write-PatchLog '=== Cleaning up patch files ==='
        Write-PatchLog "Waiting $PatchCleanupDelaySeconds seconds for file locks to clear..."
        Start-Sleep -Seconds $PatchCleanupDelaySeconds
        Remove-PatchFile -Results $toInstall -DownloadFolder $PatchDestination `
            -Retries $PatchCleanupRetries -DelaySeconds $PatchCleanupDelaySeconds
    }

    # --- Summary --------------------------------------------------------------
    Write-PatchLog ''
    Write-PatchLog '=== Patch summary ==='
    $summaryText = $results | Format-Table Category, Prefix, Latest, Check, Download, Install, Verified, Cleanup -AutoSize | Out-String -Width 250
    Write-Console $summaryText

    $missingRequired = @($results | Where-Object { $_.Check -eq 'Base app missing' })
    if ($missingRequired) {
        Write-PatchLog "Required base app(s) missing on this machine: $(($missingRequired.BaseApp) -join ', ')" -Level WARN
    }

    $failed = @($results | Where-Object {
        $_.Download -eq 'Failed' -or $_.Install -like 'Failed*' -or $_.Verified -eq $false
    })

    if ($script:RebootRequired) {
        Write-PatchLog 'A reboot is required to finish installing one or more patches.' -Level WARN
    }

    $script:PatchFailureCount = $failed.Count
    if ($failed.Count -eq 0) {
        Write-PatchLog 'Patching completed successfully.' -Level SUCCESS
    }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
$ExitCode = 1
$transcriptStarted = $false

try {
    Write-Step 1 'Pre-checks'
    Initialize-Environment

    if ($Silent) {
        # The built-in transcript only records what the console shows, so silent mode logs to $SilentLogPath instead.
        Write-Info "Silent mode: console output suppressed. Log file: $SilentLogPath"
    }
    else {
        try {
            Start-Transcript -Path $TranscriptPath -Force | Out-Null
            $transcriptStarted = $true
        }
        catch {
            Write-Warn "Could not start transcript: $($_.Exception.Message)"
        }
    }

    Stop-RunningApps
    Write-Ok "Pre-checks complete."

    if ($ForceUninstall) {
        # TEMPORARY test path: remove ImageRight regardless of version, then stop.
        Write-Step 2 'Force uninstall (test switch)'
        Write-Warn "-ForceUninstall specified: all ImageRight MSI products and the BenefitPoint launcher will be uninstalled regardless of version."
        Write-Warn "Nothing will be downloaded, installed, or patched. Run again without the switch to install."
        Uninstall-ImageRight

        if (-not $script:FolderCleanupOk) {
            Write-Warn "Uninstall finished, but one or more ImageRight folders could not be fully removed. Manual cleanup is needed."
            $ExitCode = 1
        }
        elseif ($script:RebootRequired) {
            Write-Warn "Uninstall complete. A reboot is required (exit code 3010)."
            $ExitCode = 3010
        }
        else {
            Write-Ok "Uninstall complete."
            $ExitCode = 0
        }
    }
    else {
        Write-Step 2 'Checking installed version'
        if (-not (Test-ImageRightUpToDate)) {
            Write-Step 3 'Selecting download source and downloading installer package'
            Get-InstallerPackage

            Write-Step 4 'Extracting and verifying installer package'
            Expand-InstallerPackage
            Assert-PayloadComplete

            Write-Step 5 'Removing previous ImageRight version and folders'
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
        }
        else {
            Write-Info "Steps 3-7 (base install) skipped - ImageRight is already current."
        }

        # Patching always runs, even when the base install is current. Failures here are warnings only.
        Write-Step 8 'Applying latest ImageRight patches'
        if ($SkipPatches) {
            Write-Info "Patching skipped (-SkipPatches)."
        }
        else {
            try {
                Invoke-ImageRightPatching
            }
            catch {
                Write-Warn "Patching stopped unexpectedly: $($_.Exception.Message)"
                if ($script:PatchFailureCount -lt 1) { $script:PatchFailureCount = 1 }
            }

            if ($script:PatchFailureCount -gt 0) {
                Write-Warn "$($script:PatchFailureCount) patch item(s) failed or could not be applied. This does not affect the exit code. Review the output above and the logs in $MsiLogFolder."
            }
        }

        if ($script:RebootRequired) {
            Write-Warn "ImageRight install/patching complete. A reboot is required (exit code 3010)."
            $ExitCode = 3010
        }
        else {
            Write-Ok "ImageRight install/patching complete."
            $ExitCode = 0
        }
    }
}
catch {
    Write-Console ""
    Write-Console "Installer execution failed: $($_.Exception.Message)" -ForegroundColor Red
    $ExitCode = 1
}
finally {
    Write-Step 9 'Cleaning up temporary files'
    Remove-InstallerFiles
    Write-Info "MSI logs: $MsiLogFolder"
    if ($Silent) { Write-Info "Silent log: $SilentLogPath" } else { Write-Info "Transcript: $TranscriptPath" }
    Write-Console ""
    Write-Console ("[{0}] Finished with exit code {1}." -f (Get-Date -Format 'HH:mm:ss'), $ExitCode) -ForegroundColor Cyan

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $ExitCode