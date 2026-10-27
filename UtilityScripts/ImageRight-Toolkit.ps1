#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs / upgrades ImageRight 25R1 (Vertafore) and its companion components.

.DESCRIPTION
    Run modes (chosen from a menu when the script is run interactively):
      Option 1 - Apply IR25R1 updates      : patching only (pre-checks, step 8). The base install is
                                             not touched.
      Option 2 - Install IR25R1 and update : the full flow below (install/upgrade the base, then patch).
      Option 3 - Force uninstall           : uninstalls ImageRight and the Sagitta Launcher, then deletes
                                             'C:\Program Files (x86)\ImageRight' and 'C:\ProgramData\ImageRight'.
                                             Destructive and runs WITHOUT a confirmation prompt.
      Option 4 - IR Configuration Check    : read-only report of which ImageRight config files are present and
                                             which database each one points to. Nothing is changed or closed.
      Option 5 - IR Configuration Update   : downloads the config package and replaces the present config
                                             files with the chosen set, then re-checks them:
                                               5.1 = THGx      5.2 = RIV
    For automation, pass -Option 1, 2, 3, 4, 5.1, or 5.2 to skip the menu. If no -Option is given and the
    session is not interactive (no one to answer a prompt), option 2 is used; options 3 and 5 are never
    chosen by default.
    In an interactive session the menu comes back after each option finishes and keeps coming back until Q
    is chosen. With -Option (or when not interactive) the script runs that one option and exits.

    Flow (option 2; option 1 runs only steps 1 and 8, numbered 1-2 on the console):
      1. Pre-checks (admin, C:\Temp, running apps)
      2. Detect installed version (registry, [version] comparison). If ImageRight is already current,
         steps 3-7 are skipped but patching (step 8) still runs
      3. Reuse an existing installer zip if its SHA-256 matches (e.g., left over from an interrupted run);
         otherwise download the installer zip from the Azure cloud URL (BITS first, Invoke-WebRequest as
         fallback) and verify its SHA-256 hash
      4. Expand archive and confirm every MSI / config file exists
      5. Uninstall previous ImageRight MSI products (only after payload is verified)
      6. Install MSIs in required order (each logged)
      7. Copy configs, restart installer service, apply folder permissions
      8. Apply the latest ImageRight patches (.msp) on every run: first detect which ImageRight apps are
         installed (if none, stop here without downloading anything), then discover the patches for those
         apps on the vendor release notes page, check this machine, and download, install, verify, and clean
         up only what is needed
      9. Cleanup (always runs)

    Exit codes:  0 = success / already current,  3010 = success, reboot required,  1 = failure
                 Patch failures are logged as warnings and do NOT change the exit code; the base install
                 result decides it (3010 is still returned if a patch requires a reboot).
                 Quitting from the menu exits 0 if no option was run; otherwise it exits with the exit code
                 of the last option that ran.
                 Option 3: exits 1 if any product failed to uninstall or any folder could not be fully deleted.
                 Options 4 and 5: 0 = every config passes the check, 1 = any config issue or update error.
                 (in -TestBits mode: 0 = BITS test passed,  1 = BITS test failed)

.PARAMETER Option
    Selects the run mode and skips the menu: 1 = Apply IR25R1 updates (patching only),
    2 = Install IR25R1 and update (full install, then patching), 3 = Force uninstall ImageRight and the
    Sagitta Launcher and delete their folders, 4 = IR Configuration Check (read-only report),
    5.1 = IR Configuration Update with the THGx configs, 5.2 = IR Configuration Update with the RIV configs.
    Plain 5 asks which configuration interactively and is rejected in a non-interactive session.
    If omitted, a menu is shown in an interactive session and returns after each option until Q is
    chosen; in a non-interactive session option 2 is used.

.PARAMETER SkipPatches
    Skips Step 8 (ImageRight patching). Only the base install/version check runs. Option 2 only; it cannot
    be combined with any other option.

.PARAMETER TestBits
    Tests only the BITS download path. Verifies Start-BitsTransfer and the BITS service are available,
    downloads the installer zip with BITS only (no Invoke-WebRequest fallback), verifies its SHA-256 hash,
    reports elapsed time and throughput, then deletes the test file and exits. Nothing is installed,
    uninstalled, or changed on the machine, and any existing installer zip is left untouched.

.EXAMPLE
    .\Install-ImageRight25R1.ps1

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -TestBits

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Option 1

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Option 2 -SkipPatches

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Option 3

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Option 4

.EXAMPLE
    .\Install-ImageRight25R1.ps1 -Option 5.1

.NOTES
    Version      : 1.6.0
    Baseline date: 2026-10-12
    Target       : ImageRight 25R1 (Vertafore)

    Baseline behavior - changes from here should bump the version and be logged below:
      - Download is verified by SHA-256 hash against $ExpectedSha256 (no size comparison against the server).
        A hash mismatch fails the download immediately (no retry). The hash must be updated whenever the
        installer package changes.
        If the hash is missing/invalid the script refuses to download (fails closed).
      - BUILTIN\Users keeps FullControl on 'C:\Program Files (x86)\ImageRight' (Vertafore requirement).
      - Install order of MSIs is critical and must not change.
      - Browser extension policy push is disabled ($InstallBrowserExtensions = $false).
      - Up-to-date threshold is $RequiredVersion (25.1.1.204).

    Run modes:
      - Interactive runs show a menu: 1 = Apply IR25R1 updates, 2 = Install IR25R1 and update,
        3 = Uninstall IR and Cleanup, 4 = IR Configuration Check, 5 = IR Configuration Update
        (then 1 = THGx or 2 = RIV), Q = quit. The menu returns after each option finishes and repeats until
        Q is chosen. State (reboot flag, failure counts, BITS fallback flag) is reset for every run, and the
        transcript in $TranscriptPath is appended to after the first run so earlier output is kept.
      - With -Option, or when not interactive, the script runs that one option and exits (no menu loop).
      - -Option 1, 2, 3, 4, 5.1, or 5.2 skip the menu for automation (Intune, SCCM, RMM). With no -Option and no
        interactive console, option 2 is used, which matches how earlier versions behaved. Passing -Option
        explicitly in your deployment tool is recommended.
      - -TestBits is handled before the menu and never shows it.
      - Option 1 does not run the version check, download, or install steps, leaves any installer zip
        from an interrupted run in place, and prints no cleanup or closing summary lines.
      - Option 3 (force uninstall) stops ImageRight/Sagitta processes and the installer service, runs
        msiexec /x for every product whose name matches *ImageRight* or $SagittaDisplayNamePattern, then
        deletes the folders in $ForceRemoveFolders (retrying locked files). It continues past individual
        failures so the folders are still removed, then exits 1 if anything failed. It does not touch
        per-user data (AppData), HKCU, or ImageRight registry keys outside Add/Remove Programs. Confirm the
        Sagitta Launcher's Add/Remove Programs name matches the pattern before relying on it.
      - Option 4 (config check) only reads the config files in $IRConfigFiles and reports, per file, whether
        it is present and which database it points to ($ConfigDatabases identifying strings: THGx,
        Riverlands, THG3). A file matching several strings is a multi-database instance and is noted, not
        failed. Required files must exist; optional files belong to companion apps and are noted only. It
        does not close ImageRight and prints only the check report (no cleanup or closing summary lines).
        Exit 0 = pass, 1 = any issue.
      - Option 5 (config update, 5.1 THGx / 5.2 RIV) downloads the config package ($ConfigPackageUrl, BITS
        with Invoke-WebRequest fallback, not hash-verified), extracts it, backs up each present config to
        $ConfigBackupRoot\<timestamp>, replaces it with the file from the THGx or RIV folder of the package,
        then re-runs the check. A missing required config is copied in if its application folder exists;
        if the folder is missing the application is reported as not installed (no folders are created).
        Missing optional configs are skipped. The downloaded zip and extracted folder are removed afterward,
        quietly, with no cleanup or closing summary lines (backups are kept; set $ConfigKeepPackage to keep
        the package, in which case a note says so). ImageRight is not closed; a warning
        is shown if it is running, since new configs apply after it is restarted. Exit 0 = success, 1 = any
        update error or failed re-check.

    Patching (Step 8):
      - Runs on every execution, after the base install (or on its own when ImageRight is already
        current). Finds the newest patch for each ImageRight component on the vendor release notes page
        ($PatchReleaseNotesUrl) and applies only what is missing on this machine.
      - Required components (expected everywhere) log a warning if the base app is missing; optional
        components are skipped quietly when the base app is not installed.
      - Detection gate: the base apps are detected first. If none are installed, the step ends before the
        release notes page is even fetched. Patches for apps that aren't installed are never looked up,
        downloaded, or checked.
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

    Download source:
      - All installs download from the Azure cloud URL ($ZipUrl).
      - BITS (Start-BitsTransfer) is tried first, with progress reported to the console. If BITS is
        unavailable or fails, the script falls back to Invoke-WebRequest. After a BITS failure, BITS is
        skipped for the rest of the run. The SHA-256 check applies regardless of download method.

    Change log:
      1.0.0  2026-10-12  Initial commit.
      1.1.0  2026-10-20  Downloads now use BITS (Start-BitsTransfer) with progress reporting; Invoke-WebRequest is
                         retained as a fallback if BITS is unavailable or fails. Added -TestBits switch to test
                         only the BITS download path (no install).
      1.2.0  2026-10-20  Added Step 8: ImageRight patching. Discovers the latest .msp patches on the vendor release
                         notes page, checks the machine first, then downloads (BITS with Invoke-WebRequest
                         fallback), installs, verifies, and cleans up only what is needed. Added -SkipPatches
                         switch. Cleanup is now Step 9. Fixed compressed-GUID char concatenation in the packed
                         product/patch code conversion (forces string concatenation).
      1.2.1  2026-10-20  Patching (Step 8) now runs on every execution, including when the base install is
                         already current (steps 3-7 are skipped in that case). Patch failures are now
                         warnings only and no longer affect the exit code.
      1.2.2  2026-10-20  Added $PatchRegisteredNames (patch prefix -> registered display name) for FrontEnd,
                         IRMicrosoftAddIn, IRConnect and IRDesktop patches. The "name doesn't contain ..."
                         console warning now only appears when an .msp registers under a name that differs
                         from its mapping (or when a prefix has no mapping).
      1.2.3  2026-10-20  Added $PatchRegisteredNames entries for the remaining patches: IRAdobe, IRBrowser,
                         IRWFStudio, IRAdmin and IRScanner. All patch prefixes are now mapped.
      1.3.0  2026-10-20  Added a run-mode menu: 1 = Apply IR25R1 updates (patching only), 2 = Install IR25R1 and
                         update (full flow). Added -Option 1|2 to skip the menu for automation; a
                         non-interactive session without -Option defaults to option 2.
      1.4.0  2026-10-20  Added option 3: force uninstall of ImageRight and the Sagitta Launcher plus deletion of
                         'C:\Program Files (x86)\ImageRight' and 'C:\ProgramData\ImageRight'. Interactive runs
                         require a typed YES unless -Force is used. Added -Force. -SkipPatches is now valid
                         with option 2 only.
      1.4.1  2026-10-20  Removed the typed-YES confirmation for option 3 and the -Force switch. Option 3 now runs
                         immediately when selected from the menu or passed with -Option 3.
      1.4.2  2026-10-20  Fixed an error when quitting from the menu ("The variable cannot be validated because the
                         value 0 is not a valid value for the Option variable"): the resolved choice is now kept in
                         $RunMode instead of reassigning the validated $Option parameter. Menu banner and option 3
                         label reworded.
      1.5.0  2026-10-23  Integrated the ImageRight config check/update script: option 4 = IR Configuration Check
                         (read-only report) and option 5 = IR Configuration Update with sub-options 5.1 = THGx and
                         5.2 = RIV. -Option now accepts 1, 2, 3, 4, 5, 5.1, and 5.2 (string). Options 4 and 5 do
                         not close running ImageRight processes. The config package download uses the shared
                         BITS-with-fallback downloader.
      1.5.1  2026-10-23  Option 4 (IR Configuration Check) no longer prints the cleanup step, MSI log/transcript
                         paths, or the closing "Finished with exit code" line. It now shows 2 steps.
      1.5.2  2026-10-23  Same for option 5 (IR Configuration Update): no cleanup step, "Removed ..." lines, MSI
                         log/transcript paths, or closing "Finished with exit code" line. It now shows 4 steps.
                         The downloaded package is still removed, quietly; failures to remove it are still reported.
      1.5.3  2026-10-23  Same for option 1 (Apply IR25R1 updates): no cleanup step, "No installer files" line, MSI
                         log/transcript paths, or closing "Finished with exit code" line. It now shows 2 steps.
      1.5.4  2026-10-23  Gated the patch process on app detection: the base apps are now detected first, before the
                         release notes page is fetched. If none are installed, patching ends immediately with
                         nothing downloaded. Patches for apps that aren't installed are no longer looked up,
                         downloaded, or checked.
      1.6.0  2026-10-23  The interactive menu now loops: after each option finishes it returns to the menu until Q
                         is selected. -Option and non-interactive runs still run once and exit. Run logic moved
                         into Invoke-RunMode with per-run state reset; the transcript is appended after the first
                         run. Quitting exits with the last run's exit code (0 if nothing was run).
#>

[CmdletBinding()]
param(
    [ValidateSet('1', '2', '3', '4', '5', '5.1', '5.2')][string]$Option,
    [switch]$TestBits,
    [switch]$SkipPatches
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
$ScriptVersion    = '1.6.0'                       # Keep in sync with Version in .NOTES above
$AppDisplayName   = 'ImageRight Desktop'          # Must match DisplayName in Add/Remove Programs exactly
$RequiredVersion  = [version]'25.1.1.204'         # Installed version >= this is treated as up to date
$TempRoot         = 'C:\Temp'
$ZipUrl           = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/25R1.zip'
$ZipPath          = Join-Path $TempRoot '25R1.zip'
$InstallerFolder  = Join-Path $TempRoot 'IR25R1'
$MsiLogFolder     = Join-Path $TempRoot 'ImageRightInstallLogs'
$TranscriptPath   = Join-Path $TempRoot 'Debug.txt'
$IRFolderPath     = 'C:\Program Files (x86)\ImageRight'
$IRServiceName    = 'ImageRightInstallerService'
$DownloadRetries  = 3
$BitsJobName      = 'ImageRight25R1Download'
$BitsNoProgressTimeoutSec = 120                  # Fail the BITS transfer if no bytes move for this long
$BitsReportIntervalSec    = 10                   # How often BITS progress is printed to the console

# --- ImageRight patching (Step 8) ---
$PatchReleaseNotesUrl     = 'https://help.vertafore.com/imagerightbrowserclient/content/releasenotes_25r1.htm'
$PatchDestination         = 'C:\Temp\IR_Patches'
$PatchSkipOptional        = $false               # $true = don't process the optional list at all
$PatchCleanupDelaySeconds = 5                    # Wait before cleanup (and between retries) so file locks can clear
$PatchCleanupRetries      = 3                    # How many times to try deleting a locked file
$RunStamp                 = Get-Date -Format 'yyyyMMdd_HHmmss'

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
$ExpectedSha256   = '021BD998CEED29F43883739ED08FCFE00A0E55BEBAE9C49765296D0CD8BBBD37'   # SHA-256 of 25R1.zip; update with every package change

# --- Force uninstall (option 3) ---
$SagittaDisplayNamePattern = '*Sagitta*Launcher*'   # Add/Remove Programs name of the Sagitta Launcher (wildcards ok)
$ForceRemoveFolders        = @(
    'C:\Program Files (x86)\ImageRight',
    'C:\ProgramData\ImageRight'
)
$ForceRemoveRetries        = 3                      # Attempts to delete a folder whose files are locked
$ForceRemoveDelaySeconds   = 5

# --- IR configuration check / update (options 4 and 5) ---
$ConfigPackageUrl      = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/IR-Configs.zip'
$ConfigZipPath         = Join-Path $TempRoot 'ImageRightConfigs.zip'
$ConfigExtractPath     = Join-Path $TempRoot 'ImageRightConfigs'
$ConfigBackupRoot      = Join-Path $TempRoot 'ImageRightConfigBackup'
$ConfigKeepPackage     = $false                  # $true = leave the downloaded zip and extracted files in place (troubleshooting)

# Identifying string (case-insensitive, literal match) -> database name
$ConfigDatabases = [ordered]@{
    '3033888'  = 'THGx'
    '1005220'  = 'Riverlands'
    '1019668a' = 'THG3'
}

# Update option -> folder name inside the config package
$ConfigPackageFolders = @{
    'THGx' = 'THGx'
    'RIV'  = 'RIV'
}

# Required = must exist on all devices. Optional = companion app config (missing = app not installed).
$IRConfigFiles = @(
    [PSCustomObject]@{ Name = 'ImageRight Desktop';              Required = $true;  Path = 'C:\Program Files (x86)\ImageRight\Clients\imageright.desktop.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight Installer Service';    Required = $true;  Path = 'C:\Program Files (x86)\ImageRight\InstallerService\IRInstallerService.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight Connect';              Required = $true;  Path = 'C:\Program Files (x86)\ImageRight\IRConnect\ImageRight.Connect.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight AMS360 Link';          Required = $true;  Path = 'C:\ProgramData\ImageRight\Integration\AMS360Link.config' }
    [PSCustomObject]@{ Name = 'ImageRight EMC';                  Required = $false; Path = 'C:\Program Files (x86)\ImageRight\Clients\imageright.emc.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight Workflow Studio';      Required = $false; Path = 'C:\Program Files (x86)\ImageRight\Clients\imageright.workflow.studio.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight Scanner';              Required = $false; Path = 'C:\Program Files (x86)\ImageRight\Clients\imageright.scanner.exe.config' }
    [PSCustomObject]@{ Name = 'ImageRight Configuration Editor'; Required = $false; Path = 'C:\Program Files (x86)\ImageRight\Clients\imageright.configuration.editor.exe.config' }
)

# Browser extension push is currently disabled (matches the original script).
# Set to $true to re-enable.
$InstallBrowserExtensions = $false

$script:RebootRequired = $false
$script:BitsDisabled   = $false                  # Set after a BITS failure so remaining attempts use Invoke-WebRequest
$script:TotalSteps     = 9                       # Adjusted for option 1 (patching only) after the mode is chosen
$script:PatchStep      = 8
$script:CleanupStep    = 9
$script:UninstallFailureCount = 0
$script:PatchFailureCount = 0

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
        Write-Ok "'$AppDisplayName' version $installed is already at or above required version $RequiredVersion. Base install not needed."
        return $true
    }

    Write-Info "'$AppDisplayName' version $installed is older than required $RequiredVersion. Proceeding with upgrade."
    return $false
}

# ----------------------------------------------------------------------------
# Download + SHA-256 verification
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

        # A hash mismatch is not retried: discard the file and fail immediately.
        Write-Warn "SHA-256 mismatch from $Label. Expected $ExpectedSha256 but got $actualHash. Discarding download."
        Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Leave nothing partial behind after failed attempts
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

    if (Save-InstallerFromSource -Label 'Cloud (Azure)' -Url $ZipUrl) {
        return
    }

    throw "Installer download from the cloud source failed."
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
        $msiArgs = @('/x', "`"$productCode`"", '/qn', '/norestart', "/l*v `"$logFile`"")

        # 1605 = product not installed (stale entry) - treat as OK
        Invoke-MsiStep -StepName "Uninstall $($item.DisplayName)" -Arguments $msiArgs -ExtraOkCodes @(1605)
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
        Write-Host ""
        return
    }

    switch ($Level) {
        'SUCCESS' { Write-Ok $Message }
        'WARN'    { Write-Warn $Message }
        'ERROR'   { Write-Host ("[{0}]     ERROR: {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor Red }
        'SKIP'    { Write-Host ("[{0}]     {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor DarkGray }
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

    # --- Gate: detect the base apps first -------------------------------------
    # Nothing is looked up or downloaded for an app that isn't installed. If none of the apps are present,
    # the whole patch process ends here and the release notes page isn't even fetched.
    Write-PatchLog ''
    Write-PatchLog '=== Detecting installed ImageRight applications ==='

    $installedApps       = @(Get-InstalledApplication)
    $detectedApps        = @{}      # patch prefix -> installed app entry
    $detectedItems       = @()
    $missingRequiredApps = @()

    foreach ($item in $workList) {
        $app = Test-AppInstalled -DisplayName $item.BaseApp -InstalledApps $installedApps
        if ($app) {
            $detectedApps[$item.Prefix] = $app
            $detectedItems += $item
            Write-Verbose "  Detected: $($app.DisplayName) $($app.DisplayVersion)"
        }
        elseif ($item.Category -eq 'Required') {
            Write-PatchLog "  Required app '$($item.BaseApp)' is NOT installed - skipping its patch." -Level WARN
            $missingRequiredApps += $item.BaseApp
        }
        else {
            Write-PatchLog "  '$($item.BaseApp)' not installed - skipping." -Level SKIP
        }
    }

    if (@($detectedItems).Count -eq 0) {
        Write-PatchLog 'No ImageRight applications were detected on this machine - patching skipped (nothing was downloaded).'
        return
    }

    Write-PatchLog "  $(@($detectedItems).Count) of $(@($workList).Count) application(s) detected."
    $workList = $detectedItems

    # Only now that there is something to patch: snapshot the patches Windows already has registered
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

        # Base app (already confirmed present by the detection gate above)
        $app = $detectedApps[$prefix]
        $r.BaseInstalled = $true
        $r.BaseVersion   = $app.DisplayVersion
        Write-Verbose "  Base app found: $($app.DisplayName) $($app.DisplayVersion)"

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
    Write-Host $summaryText

    if (@($missingRequiredApps).Count -gt 0) {
        Write-PatchLog "Required base app(s) missing on this machine: $($missingRequiredApps -join ', ')" -Level WARN
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
# Force uninstall (option 3)
# Uninstalls ImageRight and the Sagitta Launcher, then deletes their folders. Continues past individual
# failures so the folders are still removed; failures are counted and reported at the end.
# ----------------------------------------------------------------------------
function Invoke-ForceUninstall {
    $script:UninstallFailureCount = 0

    # Stop anything that could hold files open
    $procs = Get-Process -Name 'ImageRight*', 'Sagitta*' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Info "Stopping processes: $((($procs | Select-Object -ExpandProperty Name -Unique) -join ', '))"
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $svc = Get-Service -Name $IRServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Info "Stopping service '$IRServiceName'..."
        Stop-Service -Name $IRServiceName -Force -ErrorAction SilentlyContinue
    }

    # Find every matching product (Sagitta Launcher first, then ImageRight), without duplicates
    $allApps = @(Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName })

    $seen    = @{}
    $targets = @()
    foreach ($pattern in @($SagittaDisplayNamePattern, '*ImageRight*')) {
        foreach ($item in @($allApps | Where-Object { $_.DisplayName -like $pattern })) {
            if ($seen.ContainsKey($item.PSChildName)) { continue }
            $seen[$item.PSChildName] = $true
            $targets += $item
        }
    }

    if (@($targets).Count -eq 0) {
        Write-Info "No ImageRight or Sagitta Launcher products found in Add/Remove Programs."
        return
    }

    $total = @($targets).Count
    $n     = 0
    foreach ($item in $targets) {
        $n++
        $productCode = $item.PSChildName

        if ($productCode -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') {
            Write-Warn "Cannot uninstall non-MSI entry '$($item.DisplayName)' automatically. Remove it manually."
            $script:UninstallFailureCount++
            continue
        }

        Write-Info "Uninstalling '$($item.DisplayName)' $($item.DisplayVersion) ($n of $total)..."

        $logFile = Join-Path $MsiLogFolder ("ForceUninstall_{0}.log" -f ($productCode -replace '[{}]', ''))
        $msiArgs = @('/x', "`"$productCode`"", '/qn', '/norestart', "/l*v `"$logFile`"")

        try {
            # 1605 = product not installed (stale entry) - treat as OK
            Invoke-MsiStep -StepName "Uninstall $($item.DisplayName)" -Arguments $msiArgs -ExtraOkCodes @(1605)
        }
        catch {
            Write-Warn "$($_.Exception.Message)"
            $script:UninstallFailureCount++
        }
    }
}

function Remove-ImageRightFolders {
    foreach ($folder in $ForceRemoveFolders) {
        # Safety net: only ever delete a folder literally named ImageRight
        if ($folder -notmatch '\\ImageRight$') {
            Write-Warn "Refusing to delete unexpected path: $folder"
            $script:UninstallFailureCount++
            continue
        }

        if (-not (Test-Path -LiteralPath $folder)) {
            Write-Info "Not present, nothing to delete: $folder"
            continue
        }

        Write-Info "Deleting $folder ..."
        for ($attempt = 1; $attempt -le $ForceRemoveRetries; $attempt++) {
            try {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -lt $ForceRemoveRetries) {
                    Write-Warn "Some files in $folder are in use (attempt $attempt of $ForceRemoveRetries): $($_.Exception.Message) Retrying in $ForceRemoveDelaySeconds seconds."
                    Start-Sleep -Seconds $ForceRemoveDelaySeconds
                }
            }
        }

        if (Test-Path -LiteralPath $folder) {
            Write-Warn "Could not fully delete $folder. Files may be in use; a reboot and a second run may be needed."
            $script:UninstallFailureCount++
        }
        else {
            Write-Ok "Deleted $folder"
        }
    }
}

# ----------------------------------------------------------------------------
# ImageRight configuration check / update (options 4 and 5)
# ----------------------------------------------------------------------------
function Test-ImageRightConfigs {
    # Reports presence and database for each config. Returns the failure count (0 = pass).
    Write-Host ""
    Write-Host "ImageRight config check on $env:COMPUTERNAME" -ForegroundColor Cyan
    Write-Host ("-" * 70)

    $Results = foreach ($Config in $IRConfigFiles) {
        $File     = $Config.Path
        $Exists   = Test-Path -LiteralPath $File -PathType Leaf
        $Found    = @()
        $Note     = ""
        $ReadOK   = $false

        if ($Exists) {
            try {
                foreach ($Key in $ConfigDatabases.Keys) {
                    if (Select-String -LiteralPath $File -Pattern $Key -SimpleMatch -Quiet -ErrorAction Stop) {
                        $Found += $ConfigDatabases[$Key]
                    }
                }
                $ReadOK = $true
            }
            catch {
                $Note = "Could not read file: $($_.Exception.Message)"
            }
        }

        Write-Host ""
        Write-Host $Config.Name

        if (-not $Exists) {
            if ($Config.Required) {
                Write-Host "   Config Present   : NO (required file missing)" -ForegroundColor Red
                $Status = "Missing"
            }
            else {
                Write-Host "   Config Present   : NO (companion app not installed)" -ForegroundColor DarkGray
                $Status = "NotInstalled"
            }
            Write-Host "   Database Found   : N/A" -ForegroundColor DarkGray
        }
        else {
            Write-Host "   Config Present   : YES" -ForegroundColor Green
            if (-not $ReadOK) {
                Write-Host "   Database Found   : ERROR - $Note" -ForegroundColor Yellow
                $Status = "Unreadable"
            }
            elseif ($Found.Count -eq 1) {
                Write-Host "   Database Found   : $($Found[0])" -ForegroundColor Green
                $Status = $Found[0]
            }
            elseif ($Found.Count -gt 1) {
                Write-Host "   Database Found   : MULTI-DATABASE ($($Found -join ', '))" -ForegroundColor Yellow
                Write-Host "   Note             : Special instance - user can toggle between databases" -ForegroundColor Yellow
                $Status = "Multiple"
            }
            else {
                Write-Host "   Database Found   : NONE (no known database string)" -ForegroundColor Red
                $Status = "None"
            }
        }

        [PSCustomObject]@{
            Name     = $Config.Name
            File     = $File
            Required = $Config.Required
            Present  = $Exists
            Database = $Status
            Matches  = $Found
            Note     = $Note
        }
    }

    # Summary
    Write-Host ""
    Write-Host ("-" * 70)
    $RequiredCount = @($IRConfigFiles | Where-Object { $_.Required }).Count
    $OptionalCount = @($IRConfigFiles).Count - $RequiredCount
    Write-Host "Summary ($RequiredCount required, $OptionalCount optional):" -ForegroundColor Cyan
    foreach ($Name in $ConfigDatabases.Values) {
        $Count = @($Results | Where-Object { $_.Database -eq $Name }).Count
        if ($Count) { Write-Host ("  {0,-24}: {1}" -f $Name, $Count) -ForegroundColor Green }
    }
    $NotInstalled = @($Results | Where-Object { $_.Database -eq "NotInstalled" }).Count
    $Multiple     = @($Results | Where-Object { $_.Database -eq "Multiple" }).Count
    $NoDb         = @($Results | Where-Object { $_.Database -eq "None" }).Count
    $Missing      = @($Results | Where-Object { $_.Database -eq "Missing" }).Count
    $ReadErrors   = @($Results | Where-Object { $_.Database -eq "Unreadable" }).Count
    if ($NotInstalled) { Write-Host "  Optional not installed  : $NotInstalled" -ForegroundColor DarkGray }
    if ($Multiple)     { Write-Host "  Multi-database files    : $Multiple"     -ForegroundColor Yellow }
    if ($NoDb)         { Write-Host "  No database             : $NoDb"         -ForegroundColor Red }
    if ($Missing)      { Write-Host "  Required files missing  : $Missing"      -ForegroundColor Red }
    if ($ReadErrors)   { Write-Host "  Unreadable files        : $ReadErrors"   -ForegroundColor Yellow }

    # Multi-database (special instance) notice
    if ($Multiple) {
        $MultiDbs = @($Results | Where-Object { $_.Database -eq "Multiple" } | ForEach-Object { $_.Matches }) | Select-Object -Unique
        Write-Host ""
        Write-Host "NOTE: Multi-database instance detected." -ForegroundColor Yellow
        Write-Host "      This user can toggle between: $($MultiDbs -join ', ')" -ForegroundColor Yellow
    }

    # Pass = no required files missing, and every present file maps to at least one known database
    $PassStatuses = @($ConfigDatabases.Values) + "Multiple" + "NotInstalled"
    $Failures = @($Results | Where-Object { $PassStatuses -notcontains $_.Database }).Count

    Write-Host ""
    if ($Failures -eq 0) {
        Write-Host "RESULT: PASS" -ForegroundColor Green
    }
    else {
        Write-Host "RESULT: FAIL ($Failures issue(s))" -ForegroundColor Red
    }
    Write-Host ""

    return $Failures
}

function Get-ConfigPackage {
    # Downloads (BITS first, Invoke-WebRequest fallback) and extracts the config package.
    # Throws if it cannot be downloaded or extracted.
    Write-Info "Config package: $ConfigPackageUrl"

    # Clear any previous download/extraction so stale files are never used
    foreach ($item in @($ConfigZipPath, $ConfigExtractPath)) {
        if (Test-Path -LiteralPath $item) {
            Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
        }
    }

    $downloaded = $false
    for ($attempt = 1; $attempt -le $DownloadRetries; $attempt++) {
        Write-Info "Downloading config package (attempt $attempt of $DownloadRetries)..."
        try {
            Save-FileWithFallback -Url $ConfigPackageUrl -Destination $ConfigZipPath

            if ((Test-Path -LiteralPath $ConfigZipPath) -and (Get-Item -LiteralPath $ConfigZipPath).Length -gt 0) {
                $downloaded = $true
                break
            }
            Write-Warn "The downloaded file is missing or empty."
        }
        catch {
            Write-Warn "Download attempt $attempt failed: $($_.Exception.Message)"
        }

        if (Test-Path -LiteralPath $ConfigZipPath) {
            Remove-Item -LiteralPath $ConfigZipPath -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -lt $DownloadRetries) { Start-Sleep -Seconds 5 }
    }

    if (-not $downloaded) {
        throw "The config package could not be downloaded from $ConfigPackageUrl."
    }

    Write-Ok ("Downloaded {0:N1} MB." -f ((Get-Item -LiteralPath $ConfigZipPath).Length / 1MB))

    Write-Info "Extracting to $ConfigExtractPath ..."
    Expand-Archive -LiteralPath $ConfigZipPath -DestinationPath $ConfigExtractPath -Force -ErrorAction Stop
    Write-Ok "Extraction complete."
}

function Remove-ConfigPackage {
    # Removes the downloaded zip and extracted folder, quietly (only failures are reported). Backups are left in place.
    if ($ConfigKeepPackage) {
        Write-Info "Package cleanup skipped (`$ConfigKeepPackage is set). Files left in $TempRoot"
        return
    }

    foreach ($item in @($ConfigZipPath, $ConfigExtractPath)) {
        if (Test-Path -LiteralPath $item) {
            try {
                Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warn "Could not remove $item - $($_.Exception.Message)"
            }
        }
    }
}

function Update-ImageRightConfigs {
    # Backs up and replaces each present config from the source folder. Returns the error count.
    param(
        [string]$SourceFolder,
        [string]$Label
    )

    $BackupFolder = Join-Path $ConfigBackupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null

    Write-Host ""
    Write-Host "Replacing config files with $Label versions" -ForegroundColor Cyan
    Write-Host ("-" * 70)

    $Errors = 0
    foreach ($Config in $IRConfigFiles) {
        $FileName = Split-Path -Path $Config.Path -Leaf
        $Source   = Join-Path $SourceFolder $FileName

        Write-Host ""
        Write-Host $Config.Name

        $Present = Test-Path -LiteralPath $Config.Path -PathType Leaf

        # Optional config not present = companion app not installed; leave it alone
        if (-not $Present -and -not $Config.Required) {
            Write-Host "   Action           : SKIPPED (companion app not installed)" -ForegroundColor DarkGray
            continue
        }
        # Required config missing AND its folder missing = application not installed
        $TargetFolder = Split-Path -Path $Config.Path -Parent
        if (-not $Present -and -not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
            Write-Host "   Action           : FAILED (application not installed - folder missing: $TargetFolder)" -ForegroundColor Red
            $Errors++
            continue
        }
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            Write-Host "   Action           : FAILED ($FileName not found in $Label package folder)" -ForegroundColor Red
            $Errors++
            continue
        }

        try {
            if ($Present) {
                Copy-Item -LiteralPath $Config.Path -Destination (Join-Path $BackupFolder $FileName) -Force -ErrorAction Stop
                Copy-Item -LiteralPath $Source -Destination $Config.Path -Force -ErrorAction Stop
                Write-Host "   Action           : REPLACED with $Label config" -ForegroundColor Green
            }
            else {
                # Required config missing but application folder exists: copy it in
                Copy-Item -LiteralPath $Source -Destination $Config.Path -Force -ErrorAction Stop
                Write-Host "   Action           : COPIED $Label config (required config was missing)" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "   Action           : FAILED - $($_.Exception.Message)" -ForegroundColor Red
            $Errors++
        }
    }

    Write-Host ""
    Write-Host "Original files backed up to: $BackupFolder" -ForegroundColor Cyan
    return $Errors
}

# ----------------------------------------------------------------------------
# Run-mode menu
# ----------------------------------------------------------------------------
function Test-InteractiveSession {
    # $true if someone can answer a prompt. False for SYSTEM / service / redirected-input sessions
    # (Intune, SCCM, most RMM shells), so the script never hangs waiting for a menu choice.
    if ($Host.Name -match 'ISE') { return $true }
    if (-not [Environment]::UserInteractive) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { }
    return $true
}

function Show-ConfigMenu {
    # Sub-menu for option 5. Returns '5.1' (THGx), '5.2' (RIV), or $null for Back.
    while ($true) {
        Write-Host ""
        Write-Host "  IR Configuration Update - choose a configuration:"
        Write-Host "    1) THGx"
        Write-Host "    2) RIV"
        Write-Host "    B) Back"
        Write-Host ""

        $choice = (Read-Host "Select a configuration").Trim()
        switch -Regex ($choice) {
            '^(1|5\.1)$' { return '5.1' }
            '^(2|5\.2)$' { return '5.2' }
            '^[Bb]$'     { return $null }
            default      { Write-Warn "'$choice' is not a valid selection. Enter 1, 2, or B." }
        }
    }
}

function Show-ModeMenu {
    # Returns '1', '2', '3', '4', '5.1' (config update THGx), '5.2' (config update RIV), or '0' (quit).
    while ($true) {
        Write-Host ""
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "|                  ImageRight 25R1 Deployment                  |" -ForegroundColor Cyan
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "  1) Apply IR25R1 updates"
        Write-Host "  2) Install IR25R1 and update"
        Write-Host "  3) Uninstall IR and Cleanup"
        Write-Host "  4) IR Configuration Check"
        Write-Host "  5) IR Configuration Update"
        Write-Host "  Q) Quit"
        Write-Host ""

        $choice = (Read-Host "Select an option").Trim()
        switch -Regex ($choice) {
            '^1$'     { return '1' }
            '^2$'     { return '2' }
            '^3$'     { return '3' }
            '^4$'     { return '4' }
            '^5$'     {
                $sub = Show-ConfigMenu
                if ($sub) { return $sub }
            }
            '^[Qq]$'  { return '0' }
            default   { Write-Warn "'$choice' is not a valid selection. Enter 1, 2, 3, 4, 5, or Q." }
        }
    }
}

# ----------------------------------------------------------------------------
# BITS test mode (-TestBits): exercises only the BITS download path, installs nothing
# ----------------------------------------------------------------------------
function Invoke-BitsTest {
    $testPath = Join-Path $TempRoot 'BitsTest.zip'
    $passed   = $false

    Write-Host ""
    Write-Host "BITS test mode - nothing will be installed or changed." -ForegroundColor Cyan

    try {
        # 1. BITS cmdlet
        Write-Info "Checking for the Start-BitsTransfer cmdlet..."
        if (-not (Get-Command -Name Start-BitsTransfer -ErrorAction SilentlyContinue)) {
            throw "Start-BitsTransfer is not available on this system."
        }
        Write-Ok "Start-BitsTransfer is available."

        # 2. BITS service (it normally starts on demand, so 'Stopped' is fine; 'Disabled' is not)
        Write-Info "Checking the BITS service..."
        $svc = Get-Service -Name 'BITS' -ErrorAction SilentlyContinue
        if (-not $svc) {
            throw "The BITS service was not found."
        }
        Write-Info "BITS service status: $($svc.Status), start type: $($svc.StartType)"
        if ("$($svc.StartType)" -eq 'Disabled') {
            throw "The BITS service is disabled."
        }

        # 3. Download with BITS only (no fallback)
        if (Test-Path -LiteralPath $testPath) {
            Remove-Item -LiteralPath $testPath -Force
        }
        Write-Info "Downloading $ZipUrl with BITS only..."
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Start-BitsDownload -Url $ZipUrl -Destination $testPath
        $sw.Stop()

        $size    = (Get-Item -LiteralPath $testPath).Length
        $seconds = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        Write-Ok ("BITS download complete: {0:N0} bytes ({1:N1} MB) in {2:N1} s ({3:N1} MB/s)." -f $size, ($size / 1MB), $seconds, (($size / 1MB) / $seconds))

        # 4. Integrity
        if ($ExpectedSha256 -match '^[0-9A-Fa-f]{64}$') {
            Write-Info "Verifying SHA-256 hash..."
            $hash = (Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash
            if ($hash -ine $ExpectedSha256) {
                throw "SHA-256 mismatch. Expected $ExpectedSha256 but got $hash."
            }
            Write-Ok "SHA-256 verified."
        }
        else {
            Write-Warn "ExpectedSha256 is not a valid value; skipping hash verification in this test."
        }

        $passed = $true
    }
    catch {
        Write-Host ""
        Write-Host "BITS test failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if (Test-Path -LiteralPath $testPath) {
            Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    if ($passed) {
        Write-Host ("[{0}] BITS test PASSED." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Green
        return 0
    }
    Write-Host ("[{0}] BITS test FAILED. Installs on this machine will fall back to Invoke-WebRequest." -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Red
    return 1
}

# ----------------------------------------------------------------------------
# Run one selected option (the interactive menu can run several in one session)
# ----------------------------------------------------------------------------
function Invoke-RunMode {
    # Runs one option ('1'-'4', '5.1', '5.2') start to finish and sets $script:RunExitCode.
    # The result is passed back through $script:RunExitCode (not the pipeline).
    param([Parameter(Mandatory = $true)][string]$Selected)

    $script:RunExitCode = 1
    $script:RunCount++

    # Fresh state for every run, so one option never affects the next
    $script:RebootRequired        = $false
    $script:PatchFailureCount     = 0
    $script:UninstallFailureCount = 0
    $script:BitsDisabled          = $false
    $script:RunStamp              = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:TotalSteps            = 9
    $script:PatchStep             = 8
    $script:CleanupStep           = 9

    $RunMode       = 0
    $ConfigProfile = $null
    switch ($Selected) {
        '5.1'   { $RunMode = 5; $ConfigProfile = 'THGx' }
        '5.2'   { $RunMode = 5; $ConfigProfile = 'RIV' }
        default { $RunMode = [int]$Selected }
    }

    if ($RunMode -ne 2 -and $SkipPatches) {
        Write-Host "-SkipPatches applies only to option 2 (Install IR25R1 and update)." -ForegroundColor Red
        return
    }

    $UpdateOnly    = ($RunMode -eq 1)
    $UninstallOnly = ($RunMode -eq 3)
    $CheckOnly     = ($RunMode -eq 4)
    $ConfigUpdate  = ($RunMode -eq 5)
    $ModeLabel = switch ($RunMode) {
        1 { 'Option 1 - Apply IR25R1 updates' }
        2 { 'Option 2 - Install IR25R1 and update' }
        3 { 'Option 3 - Force uninstall ImageRight and Sagitta Launcher' }
        4 { 'Option 4 - IR Configuration Check' }
        5 { "Option $Selected - IR Configuration Update ($ConfigProfile)" }
    }
    if ($UpdateOnly) {
        $script:TotalSteps  = 2
        $script:PatchStep   = 2
        $script:CleanupStep = 2
    }
    elseif ($UninstallOnly) {
        $script:TotalSteps  = 4
        $script:CleanupStep = 4
    }
    elseif ($CheckOnly) {
        $script:TotalSteps  = 2
        $script:CleanupStep = 2
    }
    elseif ($ConfigUpdate) {
        $script:TotalSteps  = 4
        $script:CleanupStep = 4
    }

    $ExitCode = 1
    $transcriptStarted = $false

    try {
        Write-Step 1 'Pre-checks'
        Initialize-Environment

        try {
            $transcriptArgs = @{ Path = $TranscriptPath; Force = $true }
            if ($script:RunCount -gt 1) { $transcriptArgs['Append'] = $true }
            Start-Transcript @transcriptArgs | Out-Null
            $transcriptStarted = $true
        }
        catch {
            Write-Warn "Could not start transcript: $($_.Exception.Message)"
        }

        Write-Info "Script version $ScriptVersion. Mode: $ModeLabel"
        if ($CheckOnly -or $ConfigUpdate) {
            Write-Info "Running ImageRight applications are left open in this mode."
        }
        else {
            Stop-RunningApps
        }
        Write-Ok "Pre-checks complete."

        if ($CheckOnly) {
            Write-Step 2 'Checking ImageRight configuration files'
            $configFailures = Test-ImageRightConfigs

            if ($configFailures -eq 0) {
                $ExitCode = 0
            }
            else {
                Write-Warn "The configuration check found $configFailures issue(s). Exit code 1."
                $ExitCode = 1
            }
        }
        elseif ($ConfigUpdate) {
            $runningIR = Get-Process -Name 'imageright*', 'IRInstallerService' -ErrorAction SilentlyContinue
            if ($runningIR) {
                Write-Warn "ImageRight processes are running ($((($runningIR | Select-Object -ExpandProperty ProcessName -Unique) -join ', '))). New configs take effect after these apps/services are restarted."
            }

            Write-Step 2 'Downloading and extracting the config package'
            Get-ConfigPackage

            # Locate the profile folder anywhere in the extracted package (handles a wrapping top-level folder)
            $packageFolderName = $ConfigPackageFolders[$ConfigProfile]
            $configSource = Get-ChildItem -LiteralPath $ConfigExtractPath -Directory -Recurse |
                Where-Object { $_.Name -eq $packageFolderName } |
                Select-Object -First 1
            if (-not $configSource) {
                throw "Folder '$packageFolderName' was not found in the config package."
            }

            Write-Step 3 "Replacing configuration files with $ConfigProfile versions"
            $updateErrors = Update-ImageRightConfigs -SourceFolder $configSource.FullName -Label $ConfigProfile

            Write-Step 4 'Verifying configuration files'
            $configFailures = Test-ImageRightConfigs

            if ($updateErrors -gt 0 -or $configFailures -gt 0) {
                Write-Warn "Configuration update finished with $updateErrors update error(s) and $configFailures check issue(s). Exit code 1."
                $ExitCode = 1
            }
            else {
                Write-Ok "ImageRight configuration updated to $ConfigProfile."
                $ExitCode = 0
            }
        }
        elseif ($UninstallOnly) {
            Write-Step 2 'Uninstalling ImageRight and the Sagitta Launcher'
            Invoke-ForceUninstall

            Write-Step 3 'Removing ImageRight folders'
            Remove-ImageRightFolders

            if ($script:UninstallFailureCount -gt 0) {
                throw "Force uninstall finished with $($script:UninstallFailureCount) problem(s). Review the output above and the logs in $MsiLogFolder."
            }

            if ($script:RebootRequired) {
                Write-Warn "ImageRight and the Sagitta Launcher were removed, but a reboot is required to finish (exit code 3010)."
                $ExitCode = 3010
            }
            else {
                Write-Ok "ImageRight and the Sagitta Launcher were removed."
                $ExitCode = 0
            }
        }
        else {
            if ($UpdateOnly) {
                Write-Info "Applying updates only. The base install steps are skipped."

                $desktopApp = Get-ItemProperty -Path $UninstallRegistryPaths -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -eq $AppDisplayName } |
                    Select-Object -First 1
                if (-not $desktopApp) {
                    Write-Warn "'$AppDisplayName' is not installed on this machine, so most patches will be skipped. Use option 2 to install it."
                }
                $skipBaseInstall = $true
            }
            else {
                Write-Step 2 'Checking installed version'
                $skipBaseInstall = Test-ImageRightUpToDate
            }

            if (-not $skipBaseInstall) {
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
            }
            elseif (-not $UpdateOnly) {
                Write-Info "Steps 3-7 (base install) skipped - ImageRight is already current."
            }

            # Patching always runs, even when the base install is current. Failures here are warnings only.
            Write-Step $script:PatchStep 'Applying latest ImageRight patches'
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
                if ($UpdateOnly) { Write-Ok "ImageRight patching complete." }
                else             { Write-Ok "ImageRight install/patching complete." }
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
        # Options 1, 4, and 5 print no cleanup or closing summary lines. Option 5 still removes its downloaded
        # package here, quietly (only a failure to remove it is reported).
        if ($ConfigUpdate) {
            Remove-ConfigPackage
        }

        if (-not ($UpdateOnly -or $CheckOnly -or $ConfigUpdate)) {
            Write-Step $script:CleanupStep 'Cleaning up temporary files'
            if ($UninstallOnly) {
                Write-Info "No installer files were used in this mode."
            }
            else {
                Remove-InstallerFiles
            }
            Write-Info "MSI logs: $MsiLogFolder"
            Write-Info "Transcript: $TranscriptPath"
            Write-Host ""
            Write-Host ("[{0}] Finished with exit code {1}." -f (Get-Date -Format 'HH:mm:ss'), $ExitCode) -ForegroundColor Cyan
        }

        if ($transcriptStarted) {
            try { Stop-Transcript | Out-Null } catch { }
        }
    }


    $script:RunExitCode = $ExitCode
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
if ($TestBits) {
    Initialize-Environment
    exit (Invoke-BitsTest)
}

$script:RunCount    = 0
$script:RunExitCode = 0

# --- Explicit -Option: run that one option and exit with its exit code (automation) ---
# NOTE: $Option has a ValidateSet attribute that stays attached to the variable, so it is only read, never
# reassigned. The resolved choice lives in $selected.
if (-not [string]::IsNullOrEmpty($Option)) {
    $selected = $Option

    # A plain -Option 5 needs a configuration: ask interactively, otherwise require 5.1 or 5.2
    if ($selected -eq '5') {
        if (Test-InteractiveSession) {
            $selected = Show-ConfigMenu
            if (-not $selected) {
                Write-Host "No option selected. Exiting without making any changes."
                exit 0
            }
        }
        else {
            Write-Host "Option 5 (IR Configuration Update) needs a configuration. Use -Option 5.1 (THGx) or -Option 5.2 (RIV)." -ForegroundColor Red
            exit 1
        }
    }

    Invoke-RunMode -Selected $selected
    exit $script:RunExitCode
}

# --- No -Option and nobody to answer a prompt: default to option 2, run once, and exit ---
if (-not (Test-InteractiveSession)) {
    Write-Info "Non-interactive session and no -Option supplied: defaulting to option 2 (Install IR25R1 and update)."
    Invoke-RunMode -Selected '2'
    exit $script:RunExitCode
}

# --- Interactive: show the menu again after each option finishes, until Q is chosen ---
while ($true) {
    $selected = Show-ModeMenu
    if ($selected -eq '0') { break }

    Invoke-RunMode -Selected $selected
}

if ($script:RunCount -eq 0) {
    Write-Host "No option selected. Exiting without making any changes."
    exit 0
}

Write-Host ""
Write-Host "Exiting."
exit $script:RunExitCode
