<#
.SYNOPSIS
    Checks installation status and version number for a list of applications,
    plus WinGet presence, .NET Framework 3.5 status, an IPv6 registry
    configuration, hostname naming convention, a required WiFi profile, and
    presence of the Microsoft Store and Snipping Tool.

.DESCRIPTION
    Part 1: Searches the standard Windows registry uninstall locations
    (64-bit, 32-bit/WOW6432Node, and per-user) for each application name in
    $AppList, using partial ("contains") matching on the display name.

    Part 2: Checks whether winget.exe is present on PATH and reports its
    version if present.

    Part 3: Checks whether the .NET Framework 3.5 (NetFx3) Windows feature is
    enabled. If it is not enabled, this script will attempt to enable it
    (requires an elevated/Administrator PowerShell session) and reports the
    resulting status.

    Part 4: Checks the registry value:
        HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters
        DWORD: DisabledComponents
        Expected value: 0x20 (hex) / 32 (decimal)
    This is only checked and reported - it is NOT modified by this script.

    Part 5: Checks that the computer's hostname does NOT contain "SD-".
    Reports green if it does not, red if it does.

    Part 6: Checks whether the WiFi profile "HILB-WiFi" is present on the
    machine (via netsh wlan show profiles). Reports green if found, red if
    not.

    Part 7: Checks whether the Microsoft Store app package is present. If
    missing, attempts to restore it by running "wsreset -i", waits 2
    minutes, then rechecks.

    Part 8: Checks whether Snipping Tool is present (modern package or the
    legacy System32 executable).

    Part 9: Checks whether a .NET 10 runtime is installed, via
    "dotnet --list-runtimes". Check only - no remediation is attempted.

    Part 10: In Option 2 only, creates a local administrator account named
    "thgadmin" if it doesn't already exist (and adds it to Administrators
    if it exists but isn't already a member) - requires an elevated
    session. The password is entered interactively as a SecureString and
    is never stored, logged, or hardcoded anywhere in this script. Runs
    BEFORE WinGet (Part 11) and Dell Command | Update (Part 12) below, and
    is NOT gated on the other checks passing.

    Part 11: In Option 2 only, if and only if every app and every
    additional check above came back OK (nothing missing/disabled/issue -
    a [SKIPPED] check does not block this) and WinGet itself is present,
    runs "winget upgrade --all --silent" to apply any available app
    updates. Runs BEFORE Dell Command | Update (Part 12) below. In Option
    1 (quick check), available WinGet updates are listed in the console
    instead, but never applied.

    Part 12: Under the same conditions as Part 11, runs
    "dcu-cli.exe /applyUpdates -silent -reboot=disable" to install any
    pending Dell updates without rebooting the system, then reports
    whether it ran, succeeded, and what (if anything) was applied.

    Part 13: Exports all results (apps + all extra checks) to a PDF report at
    C:\hilb\HOSTNAME_build_report.pdf (HOSTNAME replaced with the device's
    actual hostname), rendered via Microsoft Edge's built-in headless
    print-to-PDF feature - no extra modules or Office required.

    All results are printed to the console, color-coded green (good/present)
    or red (missing/misconfigured).

.PARAMETER AppNames
    One or more application names (or partial names) to search for, overriding
    the hardcoded $AppList below.

.PARAMETER CsvPath
    Optional path to a CSV file with a single column "AppName" listing the
    applications to check, overriding the hardcoded $AppList below.

.EXAMPLE
    .\Check-AppInstallStatus.ps1
    (Edit $AppList below, then run with no arguments - ideally from an
    elevated PowerShell session so the .NET 3.5 check/enable step works.)

.NOTES
    - Reading registry uninstall keys and the IPv6 DisabledComponents value
      does not require admin rights.
    - Enabling .NET Framework 3.5 (if it's not already enabled) DOES require
      an elevated/Administrator PowerShell session. If not elevated, the
      script will report the current state but skip the enable attempt.
    - Part 13 writes a PDF report to C:\hilb\HOSTNAME_build_report.pdf on
      every run (HOSTNAME is the device's actual computer name), rendered
      via headless Microsoft Edge (--headless --print-to-pdf). Requires
      Edge to be present at its default install path or on PATH - it ships
      by default on Windows 10 1809+ and all Windows 11 builds. If Edge
      isn't found, the script logs a warning and skips the PDF export
      rather than failing the run. The destination folder is created
      automatically if it doesn't exist.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$AppNames,

    [string]$CsvPath,

    # 1 = Quick Check
    # 2 = Full Check 
    # Leave unset to be prompted interactively when the script runs.
    [ValidateSet(1, 2)]
    [int]$Mode
)

# ===========================================================================
# EDIT THIS LIST - the applications to check when the script is run with
# no parameters. One entry per app; partial names are fine (e.g. "Chrome"
# will match "Google Chrome").
# ===========================================================================
$AppList = @(
    "SmartDeploy Client"
    "ScreenConnect Client (aeeac260f410d99c)"
    "ScreenConnect Client (3d8353d2b9161111)"
    "AteraAgent"
    "Netskope Client"
    "Qualys Cloud Security Agent"
    "Beyond Identity Authenticator"
    "AMS360 Client"
    "Microsoft 365 Apps for enterprise - en-us"
    "Dialpad Deployment Tool"
    "Adobe Acrobat (64-bit)"
    "ImageRight Desktop"
    "Mimecast for Outlook 64-bit"
    "Google Chrome"
    "7-Zip"
    "Zoom Workplace (64-bit)"
    "ITSPlatform"
    "Sentinel Agent"
    "Dell Command | Update for Windows Universal"
)

# ===========================================================================
# OPTIONAL - friendly display names for the console report. Matching against
# the registry still uses the actual name in $AppList above (left side);
# only the console label changes (right side). Add more entries as needed.
# ===========================================================================
$FriendlyNames = @{
    "ITSPlatform" = "Connectwise RMM"
    "ScreenConnect Client (aeeac260f410d99c)" = "ScreenConnect - HILB"
    "ScreenConnect Client (3d8353d2b9161111)" = "ScreenConnect - RMM"
    "Microsoft 365 Apps for enterprise - en-us" = "Microsoft 365 Apps"
    "Dialpad Deployment Tool" = "Dialpad"
    "Dell Command | Update for Windows Universal" = "Dell Command | Update"
}

# ---------------------------------------------------------------------------
# Are we elevated? (Needed for the .NET 3.5 enable step)
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

# ---------------------------------------------------------------------------
# Mode selection - quick check vs full verification
# ---------------------------------------------------------------------------
if (-not $Mode) {
    Write-Host ""
    Write-Host "Select an option:" -ForegroundColor Cyan
    Write-Host "=================" -ForegroundColor Cyan
    Write-Host "  1) Quick software check" -ForegroundColor White
    Write-Host "     -Checks apps and system configs only" -ForegroundColor White
    Write-Host ""
    Write-Host "  2) Full verification" -ForegroundColor White
    Write-Host "     -Runs all checks to ensure device is properly configured and ready to ship" -ForegroundColor White
    Write-Host ""

    do {
        $modeSelection = Read-Host "Enter 1 or 2"
    } while ($modeSelection -notin @('1', '2'))

    $Mode = [int]$modeSelection
}

if ($Mode -eq 1) {
    Write-Host ""
    Write-Host "Running Quick software check" -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "Running Full verification" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Build the list of app names to check
# Priority: -AppNames param > -CsvPath param > hardcoded $AppList above
# ---------------------------------------------------------------------------
if ($AppNames -and $AppNames.Count -gt 0) {
    # Use whatever was passed in on the command line
}
elseif ($CsvPath) {
    if (-not (Test-Path $CsvPath)) {
        Write-Error "CSV file not found: $CsvPath"
        return
    }
    $AppNames = (Import-Csv -Path $CsvPath).AppName
}
else {
    $AppNames = $AppList
}

# ===========================================================================
# PART 1 - Installed applications (registry uninstall keys)
# ===========================================================================
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-InstalledAppsSnapshot {
    # A fresh read of the uninstall registry keys, deduplicated. Pulled out
    # into a function so it can be called again for the retry below without
    # duplicating the query logic.
    $snapshot = foreach ($keyPath in $uninstallKeys) {
        Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object `
                @{Name = 'DisplayName'; Expression = { $_.DisplayName } }, `
                @{Name = 'DisplayVersion'; Expression = { $_.DisplayVersion } }, `
                @{Name = 'Publisher'; Expression = { $_.Publisher } }, `
                @{Name = 'InstallLocation'; Expression = { $_.InstallLocation } }, `
                @{Name = 'InstallDate'; Expression = { $_.InstallDate } }
    }
    # Deduplicate (same app can appear in multiple keys, e.g. 32-bit + 64-bit views)
    return $snapshot | Sort-Object DisplayName, DisplayVersion -Unique
}

Write-Verbose "Enumerating installed applications from registry..."
$installed = Get-InstalledAppsSnapshot

$appResults = foreach ($name in $AppNames) {
    $matches = $installed | Where-Object { $_.DisplayName -like "*$name*" }

    if ($matches) {
        foreach ($m in $matches) {
            [PSCustomObject]@{
                CheckType    = 'Application'
                RequestedApp = $name
                Installed    = $true
                DisplayName  = $m.DisplayName
                Version      = $m.DisplayVersion
                Detail       = $null
            }
        }
    }
    else {
        [PSCustomObject]@{
            CheckType    = 'Application'
            RequestedApp = $name
            Installed    = $false
            DisplayName  = $null
            Version      = $null
            Detail       = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Retry once for anything that came back missing. Registry entries can
# briefly vanish mid-install/update (e.g. an agent re-registering itself),
# so a single apparent miss isn't necessarily a real miss - wait 2 seconds
# and take a fresh registry snapshot before calling it Missing for real.
# ---------------------------------------------------------------------------
$initiallyMissingNames = ($appResults | Where-Object { -not $_.Installed }).RequestedApp

if ($initiallyMissingNames) {
    Write-Verbose "Some apps showed as missing on the first pass - waiting 2 seconds and rechecking before finalizing..."
    Start-Sleep -Seconds 2
    $installedRetry = Get-InstalledAppsSnapshot

    $appResults = foreach ($name in $AppNames) {
        if ($name -notin $initiallyMissingNames) {
            # Already confirmed installed on the first pass - keep those
            # results as-is rather than re-querying everything.
            $appResults | Where-Object { $_.RequestedApp -eq $name }
            continue
        }

        $retryMatches = $installedRetry | Where-Object { $_.DisplayName -like "*$name*" }

        if ($retryMatches) {
            foreach ($m in $retryMatches) {
                [PSCustomObject]@{
                    CheckType    = 'Application'
                    RequestedApp = $name
                    Installed    = $true
                    DisplayName  = $m.DisplayName
                    Version      = $m.DisplayVersion
                    Detail       = $null
                }
            }
        }
        else {
            [PSCustomObject]@{
                CheckType    = 'Application'
                RequestedApp = $name
                Installed    = $false
                DisplayName  = $null
                Version      = $null
                Detail       = $null
            }
        }
    }
}

# ===========================================================================
# PART 2 - WinGet presence and version (reinstall/re-register and recheck
# if missing)
# ===========================================================================
function Get-WingetStatus {
    # Returns $null if not found, otherwise a hashtable with Path/Version.
    $cmd = Get-Command -Name "winget.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }

    $version = $null
    try {
        $versionRaw = & winget.exe --version 2>$null
        $version = ($versionRaw | Select-Object -First 1).ToString().Trim()
    }
    catch {
        $version = "(version unknown)"
    }

    return @{ Path = $cmd.Source; Version = $version }
}

$wingetStatus    = Get-WingetStatus
$wingetInstalled = [bool]$wingetStatus
$wingetVersion   = if ($wingetStatus) { $wingetStatus.Version } else { $null }
$wingetPath      = if ($wingetStatus) { $wingetStatus.Path } else { $null }
$wingetAction    = $null

# Capture the state as first observed, before any remediation attempt below,
# so we can distinguish "already present" from "restored during this run".
$wingetWasAlreadyEnabled = $wingetInstalled

if (-not $wingetInstalled) {
    if (-not $isAdmin) {
        $wingetAction = "Missing, and this session is not elevated - skipped reinstall attempt. Re-run as Administrator to restore."
    }
    else {
        try {
            Write-Verbose "Attempting to reinstall/re-register WinGet (Microsoft.DesktopAppInstaller)..."
            Get-AppxPackage -AllUsers *Microsoft.DesktopAppInstaller* | ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
            }
            Write-Verbose "Waiting 2 minutes before rechecking WinGet..."
            Start-Sleep -Seconds 120

            $wingetStatus = Get-WingetStatus
            if ($wingetStatus) {
                $wingetInstalled = $true
                $wingetVersion   = $wingetStatus.Version
                $wingetPath      = $wingetStatus.Path
                $wingetAction    = "Was missing - reinstall/re-register attempted during this run."
            }
            else {
                $wingetAction = "Reinstall/re-register attempted, but WinGet is still missing after rechecking."
            }
        }
        catch {
            $wingetAction = "Reinstall/re-register attempt FAILED: $($_.Exception.Message)"
        }
    }
}

$wingetResult = [PSCustomObject]@{
    CheckType        = 'WinGet'
    RequestedApp     = 'WinGet (winget.exe)'
    Installed        = $wingetInstalled
    WasAlreadyEnabled = $wingetWasAlreadyEnabled
    DisplayName      = $wingetPath
    Version          = $wingetVersion
    Detail           = $wingetAction
}

# ===========================================================================
# PART 3 - .NET Framework 3.5 (NetFx3) - check, and enable if needed
# ===========================================================================
$netFxAction      = $null
$netFxState       = $null
$netFxQueryFailed = $false

try {
    $netFx = Get-WindowsOptionalFeature -Online -FeatureName "NetFx3" -ErrorAction Stop
    $netFxState = $netFx.State   # Enabled / Disabled / DisabledWithPayloadRemoved
}
catch {
    $netFxQueryFailed = $true
    $netFxState = "Unknown"
    $netFxAction = "Unable to query feature state - this usually requires an elevated session: $($_.Exception.Message)"
}

# Capture the state as first observed, before any remediation attempt below,
# so we can distinguish "already enabled" from "enabled during this run".
$netFxWasAlreadyEnabled = ($netFxState -eq 'Enabled')

if (-not $netFxQueryFailed -and $netFxState -ne 'Enabled') {
    if (-not $isAdmin) {
        $netFxAction = "Disabled - session is not elevated, so the enable attempt was skipped. Re-run as Administrator to enable."
    }
    else {
        try {
            Write-Verbose "Attempting to enable .NET Framework 3.5..."
            Enable-WindowsOptionalFeature -Online -FeatureName "NetFx3" -All -NoRestart -ErrorAction Stop | Out-Null
            $netFxState  = (Get-WindowsOptionalFeature -Online -FeatureName "NetFx3" -ErrorAction Stop).State
            $netFxAction = "Was disabled - enable attempted during this run."
        }
        catch {
            $netFxAction = "Enable attempt FAILED: $($_.Exception.Message)"
        }
    }
}

$netFxOk = ($netFxState -eq 'Enabled')

$netFxResult = [PSCustomObject]@{
    CheckType           = '.NET 3.5'
    RequestedApp        = '.NET 3.5'
    Installed           = $netFxOk
    Skipped             = $netFxQueryFailed
    WasAlreadyEnabled    = $netFxWasAlreadyEnabled
    DisplayName         = "State: $netFxState"
    Version             = $null
    Detail              = $netFxAction
}

# ===========================================================================
# PART 4 - IPv6 DisabledComponents registry value (check only, no changes made)
# ===========================================================================
$regPath        = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$regName        = 'DisabledComponents'
$expectedDecimal = 0x20   # 32 decimal

$regActualValue = $null
$regDetail      = $null
$regOk          = $false

try {
    $regItem = Get-ItemProperty -Path $regPath -Name $regName -ErrorAction Stop
    $regActualValue = $regItem.$regName
    $regOk = ($regActualValue -eq $expectedDecimal)
    $regDetail = "Actual: 0x{0:X} ({1})  |  Expected: 0x20 (32)" -f $regActualValue, $regActualValue
}
catch {
    $regDetail = "Value not found at $regPath\$regName"
}

$regResult = [PSCustomObject]@{
    CheckType    = 'Registry'
    RequestedApp = "Prefer IPv4 over IPv6"
    Installed    = $regOk
    DisplayName  = if ($null -ne $regActualValue) { "Current value: 0x{0:X}" -f $regActualValue } else { $null }
    Version      = $null
    Detail       = $regDetail
}

# ===========================================================================
# PART 5 - Hostname naming convention (must NOT contain "SD-")
# ===========================================================================
$hostnameValue = $env:COMPUTERNAME
$hostnameBad   = $hostnameValue -like "*SD-*"
$hostnameOk    = -not $hostnameBad

$hostnameResult = [PSCustomObject]@{
    CheckType    = 'Hostname'
    RequestedApp = 'Hostname naming convention'
    Installed    = $hostnameOk
    Warning      = $hostnameBad
    DisplayName  = "Hostname: $hostnameValue"
    Version      = $null
    Detail       = if ($hostnameOk) { "Does not contain 'SD-'" } else { "Contains 'SD-'" }
}

# ===========================================================================
# PART 6 - Required WiFi profile "HILB-WiFi"
# ===========================================================================
$wifiProfileName = "HILB-WiFi"
$wifiFound       = $false
$wifiDetail      = $null

try {
    $wifiProfilesRaw = netsh wlan show profiles 2>$null
    if ($wifiProfilesRaw) {
        $wifiFound = [bool]($wifiProfilesRaw | Select-String -SimpleMatch $wifiProfileName)
    }
    $wifiDetail = if ($wifiFound) { "Profile found" } else { "Profile not found on this machine" }
}
catch {
    $wifiDetail = "Unable to query WiFi profiles: $($_.Exception.Message)"
}

$wifiResult = [PSCustomObject]@{
    CheckType    = 'WiFi Profile'
    RequestedApp = "WiFi profile: $wifiProfileName"
    Installed    = $wifiFound
    Warning      = -not $wifiFound
    DisplayName  = $null
    Version      = $null
    Detail       = $wifiDetail
}

# ===========================================================================
# PART 7 - Microsoft Store presence (re-register and recheck if missing)
# ===========================================================================
$msStorePkg       = $null
$msStoreInstalled = $false
$msStoreVersion   = $null
$msStoreAction    = $null

try {
    $msStorePkg = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue
    if ($msStorePkg) {
        $msStoreInstalled = $true
        $msStoreVersion   = $msStorePkg.Version
    }
}
catch {
    # Get-AppxPackage can throw on some locked-down/Server builds - treat as not found
}

# Capture the state as first observed, before any remediation attempt below,
# so we can distinguish "already present" from "restored during this run".
$msStoreWasAlreadyEnabled = $msStoreInstalled

if (-not $msStoreInstalled) {
    try {
        Write-Verbose "Attempting to reinstall the Microsoft Store via wsreset -i..."
        Start-Process -FilePath "wsreset.exe" -ArgumentList "-i" -WindowStyle Hidden -ErrorAction Stop

        Write-Verbose "Waiting 2 minutes before rechecking Microsoft Store..."
        Start-Sleep -Seconds 120

        $msStorePkg = Get-AppxPackage -Name "Microsoft.WindowsStore" -ErrorAction SilentlyContinue
        if ($msStorePkg) {
            $msStoreInstalled = $true
            $msStoreVersion   = $msStorePkg.Version
            $msStoreAction    = "Was missing - 'wsreset -i' attempted during this run."
        }
        else {
            $msStoreAction = "'wsreset -i' attempted, but Microsoft Store is still missing after rechecking."
        }
    }
    catch {
        $msStoreAction = "'wsreset -i' attempt FAILED: $($_.Exception.Message)"
    }
}

$msStoreResult = [PSCustomObject]@{
    CheckType           = 'MS Store'
    RequestedApp        = 'Microsoft Store'
    Installed           = $msStoreInstalled
    WasAlreadyEnabled    = $msStoreWasAlreadyEnabled
    DisplayName         = $null
    Version             = $msStoreVersion
    Detail              = $msStoreAction
}

# ===========================================================================
# PART 8 - Snipping Tool presence (reinstall and recheck if missing)
# ===========================================================================
$snipPkg         = $null
$snipExePath     = Join-Path -Path $env:WINDIR -ChildPath "System32\SnippingTool.exe"
$snipInstalled   = $false
$snipVersion     = $null
$snipSource      = $null
$snipAction      = $null

try {
    $snipPkg = Get-AppxPackage -Name "Microsoft.ScreenSketch" -ErrorAction SilentlyContinue
}
catch {
    # ignore - fall back to exe check below
}

if ($snipPkg) {
    $snipInstalled = $true
    $snipVersion   = $snipPkg.Version
    $snipSource    = "Modern package (Microsoft.ScreenSketch)"
}
elseif (Test-Path -Path $snipExePath) {
    $snipInstalled = $true
    try {
        $snipVersion = (Get-Item -Path $snipExePath).VersionInfo.ProductVersion
    }
    catch {
        $snipVersion = "(version unknown)"
    }
    $snipSource = "Legacy executable ($snipExePath)"
}

# Capture the state as first observed, before any remediation attempt below,
# so we can distinguish "already present" from "restored during this run".
$snipWasAlreadyEnabled = $snipInstalled

if (-not $snipInstalled) {
    if (-not $isAdmin) {
        $snipAction = "Missing, and this session is not elevated - skipped reinstall attempt. Re-run as Administrator to restore."
    }
    else {
        try {
            Write-Verbose "Attempting to reinstall Snipping Tool (Microsoft.ScreenSketch)..."
            Get-AppxPackage -AllUsers *Microsoft.ScreenSketch* | ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -ErrorAction Stop
            }
            Write-Verbose "Waiting 2 minutes before rechecking Snipping Tool..."
            Start-Sleep -Seconds 120

            $snipPkg = Get-AppxPackage -Name "Microsoft.ScreenSketch" -ErrorAction SilentlyContinue
            if ($snipPkg) {
                $snipInstalled = $true
                $snipVersion   = $snipPkg.Version
                $snipSource    = "Modern package (Microsoft.ScreenSketch)"
                $snipAction    = "Was missing - reinstall attempted during this run."
            }
            elseif (Test-Path -Path $snipExePath) {
                $snipInstalled = $true
                try {
                    $snipVersion = (Get-Item -Path $snipExePath).VersionInfo.ProductVersion
                }
                catch {
                    $snipVersion = "(version unknown)"
                }
                $snipSource = "Legacy executable ($snipExePath)"
                $snipAction = "Was missing - reinstall attempted during this run (found via legacy exe on recheck)."
            }
            else {
                $snipAction = "Reinstall attempted, but Snipping Tool is still missing after rechecking."
            }
        }
        catch {
            $snipAction = "Reinstall attempt FAILED: $($_.Exception.Message)"
        }
    }
}

$snipResult = [PSCustomObject]@{
    CheckType           = 'Snipping Tool'
    RequestedApp        = 'Snipping Tool'
    Installed           = $snipInstalled
    WasAlreadyEnabled    = $snipWasAlreadyEnabled
    DisplayName         = $snipSource
    Version             = $snipVersion
    Detail              = $snipAction
}

# ===========================================================================
# PART 9 - .NET 10 runtime presence (check only, no remediation)
# ===========================================================================
$dotnet10Found   = $false
$dotnet10Version = $null
$dotnet10Detail  = $null

$dotnetCmd = Get-Command -Name "dotnet.exe" -ErrorAction SilentlyContinue
if (-not $dotnetCmd) {
    $dotnet10Detail = "dotnet.exe not found on PATH"
}
else {
    try {
        $runtimesRaw = & dotnet.exe --list-runtimes 2>$null
        $matchingRuntimes = $runtimesRaw | Where-Object { $_ -match '^\S+\s+10\.' }
        if ($matchingRuntimes) {
            $dotnet10Found = $true
            $firstMatchParts = ($matchingRuntimes | Select-Object -First 1) -split '\s+'
            $dotnet10Version = $firstMatchParts[1]
            $dotnet10Detail  = ($matchingRuntimes -join '; ')
        }
        else {
            $dotnet10Detail = "No .NET 10 runtime found via 'dotnet --list-runtimes'"
        }
    }
    catch {
        $dotnet10Detail = "Unable to query installed .NET runtimes: $($_.Exception.Message)"
    }
}

$dotnet10Result = [PSCustomObject]@{
    CheckType    = '.NET 10'
    RequestedApp = '.NET 10 Runtime'
    Installed    = $dotnet10Found
    DisplayName  = $null
    Version      = $dotnet10Version
    Detail       = $dotnet10Detail
}

# ===========================================================================
# Combine all results
# ===========================================================================
$results = @($appResults) + @($wingetResult) + @($netFxResult) + @($regResult) + `
           @($hostnameResult) + @($wifiResult) + @($msStoreResult) + @($snipResult) + `
           @($dotnet10Result)

# ===========================================================================
# Output - color-coded per-item console report
# ===========================================================================
Write-Host ""
Write-Host "Application Installation Status" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

$grouped = $appResults | Group-Object RequestedApp

# First pass: resolve the display name/version text for each app without
# printing yet, so we can measure the longest name and align every
# "| Version:" column underneath it.
$appLines = foreach ($group in $grouped) {
    $entries = $group.Group

    if ($entries[0].Installed) {
        # If the same requested app matched multiple registry entries (e.g. a
        # 32-bit and 64-bit uninstall key both registering the same product),
        # report just one line - prefer the entry with the most detailed
        # version string.
        $entry = $entries | Sort-Object { ($_.Version | Out-String).Trim().Length } -Descending | Select-Object -First 1

        $displayRequestedName = if ($FriendlyNames.ContainsKey($entry.RequestedApp)) {
            $FriendlyNames[$entry.RequestedApp]
        }
        else {
            $entry.RequestedApp
        }

        $versionText = if ($entry.Version) { $entry.Version } else { "(version unknown)" }
        $nameText = if ($entry.DisplayName -eq $entry.RequestedApp -or $entry.DisplayName.StartsWith($entry.RequestedApp, [System.StringComparison]::OrdinalIgnoreCase)) {
            $displayRequestedName
        }
        else {
            "$displayRequestedName -> $($entry.DisplayName)"
        }

        [PSCustomObject]@{
            Installed   = $true
            NameText    = $nameText
            VersionText = $versionText
        }
    }
    else {
        $displayMissingName = if ($FriendlyNames.ContainsKey($group.Name)) {
            $FriendlyNames[$group.Name]
        }
        else {
            $group.Name
        }

        [PSCustomObject]@{
            Installed   = $false
            NameText    = $displayMissingName
            VersionText = $null
        }
    }
}

# Alphabetical order (case-insensitive) by displayed name, for both the
# console and the PDF (which reuses this same sorted $appLines array).
$appLines = $appLines | Sort-Object { $_.NameText.ToLowerInvariant() }

$maxAppNameLength = ($appLines | ForEach-Object { $_.NameText.Length } | Measure-Object -Maximum).Maximum

# Second pass: print, padding every name to the same width so the
# "| Version:" (and "| Not found...") columns line up.
foreach ($line in $appLines) {
    $paddedName = $line.NameText.PadRight($maxAppNameLength)

    if ($line.Installed) {
        Write-Host "[INSTALLED] " -ForegroundColor Green -NoNewline
        Write-Host "$paddedName  |  Version: $($line.VersionText)" -ForegroundColor White -BackgroundColor Black
    }
    else {
        Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
        Write-Host "$paddedName  |  Not found on this system" -ForegroundColor White -BackgroundColor Black
    }
}

Write-Host ""
Write-Host "Additional System Checks" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Build one entry per check (Tag/StatusClass/Body), rather than printing
# directly, so the whole set can be sorted alphabetically before display.
# StatusClass maps 1:1 to both a console color and a PDF CSS class:
# 'ok' = Green, 'issue' = Red, 'skipped' = Yellow (used for both [SKIPPED]
# and [WARNING] - a soft fail is still yellow). This same list is reused
# later when building the PDF, so console and PDF always match.
$additionalChecksDisplay = @()

# WinGet
if ($wingetResult.Installed -and $wingetResult.WasAlreadyEnabled) {
    $line = "$($wingetResult.RequestedApp)"
    if ($wingetResult.Version) { $line += "  |  Version: $($wingetResult.Version)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $wingetResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = $line }
}
elseif ($wingetResult.Installed) {
    $line = "$($wingetResult.RequestedApp)"
    if ($wingetResult.Version) { $line += "  |  Version: $($wingetResult.Version)" }
    if ($wingetResult.Detail)  { $line += "  |  $($wingetResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $wingetResult.RequestedApp; Tag = "[ENABLED]"; StatusClass = 'ok'; Body = $line }
}
else {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $wingetResult.RequestedApp; Tag = "[MISSING]"; StatusClass = 'issue'; Body = "$($wingetResult.RequestedApp)  |  $($wingetResult.Detail)" }
}

# .NET 3.5
if ($netFxResult.Skipped) {
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $netFxResult.RequestedApp; Tag = "[SKIPPED]"; StatusClass = 'skipped'; Body = $line }
}
elseif ($netFxResult.Installed -and $netFxResult.WasAlreadyEnabled) {
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $netFxResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = $line }
}
elseif ($netFxResult.Installed) {
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $netFxResult.RequestedApp; Tag = "[ENABLED]"; StatusClass = 'ok'; Body = $line }
}
else {
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $netFxResult.RequestedApp; Tag = "[DISABLED]"; StatusClass = 'issue'; Body = $line }
}

# Registry key
if ($regResult.Installed) {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $regResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = "$($regResult.RequestedApp)" }
}
else {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $regResult.RequestedApp; Tag = "[ISSUE]"; StatusClass = 'issue'; Body = "$($regResult.RequestedApp)  |  $($regResult.Detail)" }
}

# Hostname naming convention and WiFi profile - full verification (Option 2)
# only. Both are still computed above regardless of mode (they're cheap,
# no remediation/waiting involved) but are only reported in Option 2.
if ($Mode -eq 2) {
    if ($hostnameResult.Installed) {
        $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $hostnameResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" }
    }
    else {
        $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $hostnameResult.RequestedApp; Tag = "[WARNING]"; StatusClass = 'skipped'; Body = "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" }
    }

    if ($wifiResult.Installed) {
        $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $wifiResult.RequestedApp; Tag = "[FOUND]"; StatusClass = 'ok'; Body = "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" }
    }
    else {
        $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $wifiResult.RequestedApp; Tag = "[WARNING]"; StatusClass = 'skipped'; Body = "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" }
    }
}

# Microsoft Store
if ($msStoreResult.Installed -and $msStoreResult.WasAlreadyEnabled) {
    $line = "$($msStoreResult.RequestedApp)"
    if ($msStoreResult.Version) { $line += "  |  Version: $($msStoreResult.Version)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $msStoreResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = $line }
}
elseif ($msStoreResult.Installed) {
    $line = "$($msStoreResult.RequestedApp)"
    if ($msStoreResult.Version) { $line += "  |  Version: $($msStoreResult.Version)" }
    if ($msStoreResult.Detail)  { $line += "  |  $($msStoreResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $msStoreResult.RequestedApp; Tag = "[ENABLED]"; StatusClass = 'ok'; Body = $line }
}
else {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $msStoreResult.RequestedApp; Tag = "[MISSING]"; StatusClass = 'issue'; Body = "$($msStoreResult.RequestedApp)  |  $($msStoreResult.Detail)" }
}

# Snipping Tool
if ($snipResult.Installed -and $snipResult.WasAlreadyEnabled) {
    $line = "$($snipResult.RequestedApp)"
    if ($snipResult.DisplayName) { $line += "  |  $($snipResult.DisplayName)" }
    if ($snipResult.Version)     { $line += "  |  Version: $($snipResult.Version)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $snipResult.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = $line }
}
elseif ($snipResult.Installed) {
    $line = "$($snipResult.RequestedApp)"
    if ($snipResult.DisplayName) { $line += "  |  $($snipResult.DisplayName)" }
    if ($snipResult.Version)     { $line += "  |  Version: $($snipResult.Version)" }
    if ($snipResult.Detail)      { $line += "  |  $($snipResult.Detail)" }
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $snipResult.RequestedApp; Tag = "[ENABLED]"; StatusClass = 'ok'; Body = $line }
}
else {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $snipResult.RequestedApp; Tag = "[MISSING]"; StatusClass = 'issue'; Body = "$($snipResult.RequestedApp)  |  $($snipResult.Detail)" }
}

# .NET 10
if ($dotnet10Result.Installed) {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $dotnet10Result.RequestedApp; Tag = "[OK]"; StatusClass = 'ok'; Body = "$($dotnet10Result.RequestedApp)  |  Version: $($dotnet10Result.Version)" }
}
else {
    $additionalChecksDisplay += [PSCustomObject]@{ SortKey = $dotnet10Result.RequestedApp; Tag = "[MISSING]"; StatusClass = 'issue'; Body = "$($dotnet10Result.RequestedApp)  |  $($dotnet10Result.Detail)" }
}

# Alphabetical order (case-insensitive), then print
$additionalChecksDisplay = $additionalChecksDisplay | Sort-Object { $_.SortKey.ToLowerInvariant() }

foreach ($entry in $additionalChecksDisplay) {
    $tagColor = switch ($entry.StatusClass) {
        'ok'      { 'Green' }
        'issue'   { 'Red' }
        'skipped' { 'Yellow' }
    }
    $paddedTag = $entry.Tag.PadRight(12)
    Write-Host $paddedTag -ForegroundColor $tagColor -NoNewline
    Write-Host $entry.Body -ForegroundColor White -BackgroundColor Black
}

Write-Host ""

# ===========================================================================
# Summary counts (computed here since the Dell Command | Update gate below
# needs them; the actual Summary line prints at the very bottom, after the
# Dell Command | Update section).
# ===========================================================================
$installedCount = ($appLines | Where-Object { $_.Installed }).Count
$missingCount    = ($appLines | Where-Object { -not $_.Installed }).Count
$extraChecks     = @($wingetResult, $netFxResult, $regResult, $msStoreResult, $snipResult, $dotnet10Result)
if ($Mode -eq 2) {
    $extraChecks += @($hostnameResult, $wifiResult)
}
$extraSkipped    = $extraChecks | Where-Object { $_.Skipped -eq $true }
$extraWarnings   = $extraChecks | Where-Object { -not $_.Skipped -and $_.Warning -eq $true }
$extraOk         = $extraChecks | Where-Object { -not $_.Skipped -and -not $_.Warning -and $_.Installed }
$extraIssues     = $extraChecks | Where-Object { -not $_.Skipped -and -not $_.Warning -and -not $_.Installed }

# ===========================================================================
# PART 10 - Local admin account: create "thgadmin" if it doesn't exist
# ===========================================================================
# Runs in Option 2, BEFORE WinGet (Part 11) and Dell Command | Update
# (Part 12) below. Unlike those two steps, this is NOT gated on the other
# checks passing - it's treated as a standard provisioning step rather than
# a conditional remediation. Requires an elevated session.
#
# The password is entered interactively as a SecureString - it is never
# stored, logged, written to disk, or hardcoded anywhere in this script.
# If the account already exists, its password is left untouched; the script
# only makes sure it's a member of Administrators.
if ($Mode -eq 2) {
$localAdminUsername      = "thgadmin"
$localAdminRan           = $false
$localAdminSuccess       = $false
$localAdminAlreadyExisted = $false
$localAdminDetail        = $null

if (-not $isAdmin) {
    $localAdminDetail = "Skipped - this session is not elevated. Re-run as Administrator to create the local admin account."
}
else {
    $existingLocalAdmin = Get-LocalUser -Name $localAdminUsername -ErrorAction SilentlyContinue

    if ($existingLocalAdmin) {
        $localAdminRan            = $true
        $localAdminAlreadyExisted = $true
        try {
            $isAlreadyAdminMember = (Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop) |
                Where-Object { $_.Name -like "*\$localAdminUsername" -or $_.Name -eq $localAdminUsername }

            if (-not $isAlreadyAdminMember) {
                Add-LocalGroupMember -Group "Administrators" -Member $localAdminUsername -ErrorAction Stop
                $localAdminDetail = "Account '$localAdminUsername' already existed - was not in Administrators, so it was added. Password left unchanged."
            }
            else {
                $localAdminDetail = "Account '$localAdminUsername' already exists and is already an Administrator - left unchanged."
            }
            $localAdminSuccess = $true
        }
        catch {
            $localAdminDetail = "Account '$localAdminUsername' already exists, but checking/updating its Administrators membership FAILED: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host ""
        Write-Host "Creating local admin account '$localAdminUsername'." -ForegroundColor Cyan
        Write-Host "Enter a password for this account now - it is used only in this session and is never stored, logged, or written to disk." -ForegroundColor Cyan

        $localAdminPassword = $null
        $passwordsMatch = $false

        while (-not $passwordsMatch) {
            $pw1 = Read-Host -AsSecureString -Prompt "New password for $localAdminUsername"
            $pw2 = Read-Host -AsSecureString -Prompt "Confirm password"

            $pw1Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1)
            $pw2Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2)
            $pw1Plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pw1Ptr)
            $pw2Plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pw2Ptr)

            if (-not [string]::IsNullOrEmpty($pw1Plain) -and $pw1Plain -ceq $pw2Plain) {
                $passwordsMatch = $true
                $localAdminPassword = $pw1
            }
            else {
                Write-Host "Passwords did not match (or were empty) - try again." -ForegroundColor Yellow
            }

            # Clear plaintext copies from memory as soon as they've been compared
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pw1Ptr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pw2Ptr)
            $pw1Plain = $null
            $pw2Plain = $null
        }

        try {
            New-LocalUser -Name $localAdminUsername -Password $localAdminPassword -FullName "THG Admin" -Description "Local admin account created by build script" -AccountNeverExpires -ErrorAction Stop | Out-Null
            Add-LocalGroupMember -Group "Administrators" -Member $localAdminUsername -ErrorAction Stop

            $localAdminRan     = $true
            $localAdminSuccess = $true
            $localAdminDetail  = "Account '$localAdminUsername' created and added to Administrators."
        }
        catch {
            $localAdminDetail = "FAILED to create/configure '$localAdminUsername': $($_.Exception.Message)"
        }
        finally {
            # Drop the reference to the SecureString now that we're done with it
            $localAdminPassword = $null
        }
        Write-Host ""
    }
}

$localAdminResult = [PSCustomObject]@{
    CheckType      = 'Local Admin Account'
    RequestedApp   = "Local admin account ($localAdminUsername)"
    Ran            = $localAdminRan
    Success        = $localAdminSuccess
    AlreadyExisted = $localAdminAlreadyExisted
    Detail         = $localAdminDetail
}

$results += @($localAdminResult)

Write-Host "Local Admin Account" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan
if (-not $localAdminResult.Ran) {
    Write-Host "[SKIPPED]   " -ForegroundColor Yellow -NoNewline
    Write-Host "$($localAdminResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
elseif ($localAdminResult.Success) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($localAdminResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($localAdminResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
Write-Host ""
}

# ===========================================================================
# PART 11 - WinGet: apply available updates (gated on a clean run)
# ===========================================================================
# Only runs in Option 2 (full verification), only if every app and every
# additional system check came back OK (same gate as Dell Command | Update
# below), and only if WinGet itself is actually present and working. First
# lists what currently has an update available (so we can name names in the
# report), then runs "winget upgrade --all" unattended, before Dell Command
# | Update, so app updates land before the Dell driver/firmware pass.
function Get-WingetPendingUpgradeNames {
    # Parses "winget upgrade" text-table output to pull out just the Name
    # column. Best-effort: winget's table is fixed-width, not a structured
    # format, so this relies on the header row's column positions. Returns
    # an empty array (never throws) if the output doesn't look as expected.
    try {
        $raw = & winget.exe upgrade --accept-source-agreements 2>$null
    }
    catch {
        return @()
    }
    if (-not $raw) { return @() }

    $headerIndex = -1
    for ($i = 0; $i -lt $raw.Count; $i++) {
        if ($raw[$i] -match '^Name\s+Id\s+Version') {
            $headerIndex = $i
            break
        }
    }
    if ($headerIndex -lt 0) { return @() }

    $idColumnStart = $raw[$headerIndex].IndexOf('Id')
    if ($idColumnStart -lt 0) { return @() }

    $names = @()
    for ($i = $headerIndex + 2; $i -lt $raw.Count; $i++) {
        $line = $raw[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line.Length -lt $idColumnStart) { continue }
        $name = $line.Substring(0, $idColumnStart).Trim()
        if ($name) { $names += $name }
    }
    return $names
}

if ($Mode -eq 2) {
$allChecksPassed = ($missingCount -eq 0 -and $extraIssues.Count -eq 0)

$wingetUpgradeRan      = $false
$wingetUpgradeSuccess  = $false
$wingetUpgradeExitCode = $null
$wingetUpgradeDetail   = $null
$wingetPendingNames    = @()

if (-not $allChecksPassed) {
    $wingetUpgradeDetail = "Skipped - one or more app or system checks were not OK, so updates were not applied."
}
elseif (-not $wingetResult.Installed) {
    $wingetUpgradeDetail = "Skipped - WinGet is not available on this system."
}
else {
    Write-Verbose "Checking for available WinGet upgrades..."
    $wingetPendingNames = Get-WingetPendingUpgradeNames

    if (-not $wingetPendingNames -or $wingetPendingNames.Count -eq 0) {
        $wingetUpgradeRan     = $true
        $wingetUpgradeSuccess = $true
        $wingetUpgradeDetail  = "No updates available - everything is already up to date."
    }
    else {
        try {
            Write-Verbose "Running winget upgrade --all ..."
            Write-Host ""
            Write-Host "WinGet found updates for:" -ForegroundColor Cyan
            foreach ($pendingName in $wingetPendingNames) {
                Write-Host "  - $pendingName" -ForegroundColor Cyan
            }
            Write-Host "Applying now - this can take a few minutes. Please wait..." -ForegroundColor Cyan
            $wingetArgs = @(
                "upgrade",
                "--all",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--disable-interactivity"
            )
            $wingetProc = Start-Process -FilePath "winget.exe" -ArgumentList $wingetArgs -Wait -PassThru -WindowStyle Hidden
            $wingetUpgradeRan      = $true
            $wingetUpgradeExitCode = $wingetProc.ExitCode
            Write-Host "WinGet finished (exit code $wingetUpgradeExitCode)." -ForegroundColor Cyan
            Write-Host ""

            if ($wingetUpgradeExitCode -eq 0) {
                $wingetUpgradeSuccess = $true
                $wingetUpgradeDetail  = "Updated:"
            }
            else {
                # WinGet's non-zero exit codes aren't documented as cleanly as
                # Dell Command | Update's - report the raw code rather than
                # guessing at a specific cause. The names attempted are still
                # listed below via PendingNames.
                $wingetUpgradeDetail = "Attempted (winget exited with code $wingetUpgradeExitCode - one or more may not have applied):"
            }
        }
        catch {
            $wingetUpgradeDetail = "Failed to launch winget.exe: $($_.Exception.Message)"
        }
    }
}

$wingetUpgradeResult = [PSCustomObject]@{
    CheckType     = 'WinGet Upgrade'
    RequestedApp  = 'WinGet - Apply Updates'
    Ran           = $wingetUpgradeRan
    Success       = $wingetUpgradeSuccess
    ExitCode      = $wingetUpgradeExitCode
    PendingNames  = $wingetPendingNames
    Detail        = $wingetUpgradeDetail
}

$results += @($wingetUpgradeResult)

Write-Host "WinGet - Apply Updates" -ForegroundColor Cyan
Write-Host "=======================" -ForegroundColor Cyan
if (-not $allChecksPassed -or -not $wingetUpgradeResult.Ran) {
    Write-Host "[SKIPPED]   " -ForegroundColor Yellow -NoNewline
    Write-Host "$($wingetUpgradeResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
elseif ($wingetUpgradeResult.Success) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($wingetUpgradeResult.Detail)" -ForegroundColor White -BackgroundColor Black
    foreach ($updatedName in $wingetUpgradeResult.PendingNames) {
        Write-Host "            - $updatedName" -ForegroundColor White -BackgroundColor Black
    }
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($wingetUpgradeResult.Detail)" -ForegroundColor White -BackgroundColor Black
    foreach ($updatedName in $wingetUpgradeResult.PendingNames) {
        Write-Host "            - $updatedName" -ForegroundColor White -BackgroundColor Black
    }
}
Write-Host ""
}

# ===========================================================================
# PART 12 - Dell Command | Update: apply updates (gated on a clean run)
# ===========================================================================
# Only runs in Option 2 (full verification) - and even then, only if every
# app and every additional system check came back OK, i.e.
# $missingCount -eq 0 and $extraIssues.Count -eq 0. A [SKIPPED] check
# (couldn't verify, e.g. .NET 3.5 without elevation) does NOT block this -
# only a confirmed [MISSING]/[ISSUE]/[DISABLED] does. Runs
# "dcu-cli.exe /applyUpdates -silent -reboot=disable" so updates are
# installed but the system is never rebooted automatically.
if ($Mode -eq 2) {
$dcuRan            = $false
$dcuSuccess        = $false
$dcuRebootRequired = $false
$dcuExitCode       = $null
$dcuDetail         = $null

if (-not $allChecksPassed) {
    $dcuDetail = "Skipped - one or more app or system checks were not OK, so updates were not applied."
}
else {
    $dcuCliPath = @(
        "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    ) | Where-Object { Test-Path -Path $_ } | Select-Object -First 1

    if (-not $dcuCliPath) {
        $dcuDetail = "All checks passed, but dcu-cli.exe was not found at its default install paths - skipped apply."
    }
    else {
        $dcuLogPath   = "C:\hilb\$($env:COMPUTERNAME)_dcu_apply.log"
        $dcuLogFolder = Split-Path -Path $dcuLogPath -Parent
        if ($dcuLogFolder -and -not (Test-Path -Path $dcuLogFolder)) {
            New-Item -ItemType Directory -Path $dcuLogFolder -Force | Out-Null
        }

        try {
            Write-Verbose "Running dcu-cli.exe /applyUpdates -reboot=disable ..."
            Write-Host ""
            Write-Host "Dell Command | Update is now scanning and applying updates - this can take several minutes. Please wait..." -ForegroundColor Cyan
            $dcuArgs = @(
                "/applyUpdates",
                "-silent",
                "-reboot=disable",
                "-outputLog=`"$dcuLogPath`""
            )
            $dcuProc = Start-Process -FilePath $dcuCliPath -ArgumentList $dcuArgs -Wait -PassThru -WindowStyle Hidden
            $dcuRan      = $true
            $dcuExitCode = $dcuProc.ExitCode
            Write-Host ""
            Write-Host "Dell Command | Update finished."
            Write-Host ""

            switch ($dcuExitCode) {
                0       { $dcuSuccess = $true; $dcuDetail = "Updates applied successfully." }
                1       { $dcuSuccess = $true; $dcuRebootRequired = $true; $dcuDetail = "Updates applied successfully - a reboot is required to complete installation." }
                500     { $dcuSuccess = $true; $dcuDetail = "No updates were found - system is already up to date." }
                4       { $dcuDetail = "dcu-cli was not launched with administrative privileges." }
                5       { $dcuDetail = "A reboot was already pending from a previous operation before this run." }
                6       { $dcuDetail = "Another instance of Dell Command | Update (UI or CLI) was already running." }
                default { $dcuDetail = "dcu-cli exited with code $dcuExitCode." }
            }
        }
        catch {
            $dcuDetail = "Failed to launch dcu-cli.exe: $($_.Exception.Message)"
        }
    }
}

$dcuApplyResult = [PSCustomObject]@{
    CheckType      = 'Dell Command Update'
    RequestedApp   = 'Dell Command | Update - Apply Updates'
    Ran            = $dcuRan
    Success        = $dcuSuccess
    RebootRequired = $dcuRebootRequired
    ExitCode       = $dcuExitCode
    Detail         = $dcuDetail
}

$results += @($dcuApplyResult)

Write-Host "Dell Command | Update - Apply Updates" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
if (-not $allChecksPassed -or -not $dcuApplyResult.Ran) {
    Write-Host "[SKIPPED]   " -ForegroundColor Yellow -NoNewline
    Write-Host "$($dcuApplyResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
elseif ($dcuApplyResult.Success) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($dcuApplyResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($dcuApplyResult.Detail) (exit code $($dcuApplyResult.ExitCode))" -ForegroundColor White -BackgroundColor Black
}
Write-Host ""

# ---------------------------------------------------------------------------
# If the hostname matched the "SD-" filter earlier, offer to rename the PC
# now that Dell Command | Update has finished. Renaming requires a reboot to
# take effect, and (like any computer rename) requires an elevated session.
# ---------------------------------------------------------------------------
$renameSucceeded = $false
$newHostnameValue = $null

if ($hostnameResult.Warning) {
    Write-Host "Reminder: this PC's hostname ($hostnameValue) contains 'SD-' and should be renamed." -ForegroundColor Yellow
    $renameChoice = Read-Host "Would you like to rename it now? (y/n)"

    if ($renameChoice -match '^(y|yes)$') {
        if (-not $isAdmin) {
            Write-Host "Cannot rename the computer - this session is not elevated. Re-run as Administrator to rename." -ForegroundColor Yellow
        }
        else {
            $newHostname = Read-Host "Enter the new hostname"
            if ([string]::IsNullOrWhiteSpace($newHostname)) {
                Write-Host "No hostname entered - skipping rename." -ForegroundColor Yellow
            }
            else {
                try {
                    Rename-Computer -NewName $newHostname -Force -ErrorAction Stop
                    Write-Host "Renamed to '$newHostname'. A restart is required for the change to take effect." -ForegroundColor Green
                    $renameSucceeded  = $true
                    $newHostnameValue = $newHostname
                }
                catch {
                    Write-Host "Rename FAILED: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
    else {
        Write-Host "Skipping rename - remember to rename this PC before deployment." -ForegroundColor Yellow
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Final hostname status - printed here (and included in the PDF) so it's
# clear exactly what the hostname is, or will become, before any reboot.
# ---------------------------------------------------------------------------
$finalHostnameStatus = if ($renameSucceeded) {
    "Hostname: $hostnameValue -> will be renamed to '$newHostnameValue' after restart"
}
else {
    "Hostname: $hostnameValue (unchanged)"
}
Write-Host "$finalHostnameStatus" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Reboot decision:
#   - Dell Command | Update ran with NO updates AND hostname NOT renamed -> no reboot
#   - Dell Command | Update ran with NO updates AND hostname renamed    -> reboot (20s delay)
#   - Dell Command | Update ran WITH updates AND hostname NOT renamed   -> reboot (20s delay)
#   - Dell Command | Update ran WITH updates AND hostname renamed       -> reboot (20s delay)
# In short: reboot if either the hostname was renamed or updates were
# actually applied (exit code 0/1 - NOT 500, which means "no updates found").
# ---------------------------------------------------------------------------
$dcuAppliedUpdates = ($dcuApplyResult.Success -and $dcuExitCode -ne 500)
$shouldReboot      = ($renameSucceeded -or $dcuAppliedUpdates)
}

# ===========================================================================
# Summary (printed last, at the bottom of the console output)
# ===========================================================================
Write-Host "Summary: " -NoNewline
Write-Host "$installedCount apps installed" -ForegroundColor Green -NoNewline
Write-Host " / " -NoNewline
Write-Host "$missingCount apps missing" -ForegroundColor Red -NoNewline
Write-Host "   |   " -NoNewline
Write-Host "$($extraOk.Count) extra checks OK" -ForegroundColor Green -NoNewline
Write-Host " / " -NoNewline
Write-Host "$($extraIssues.Count) extra checks need attention" -ForegroundColor Red -NoNewline
if ($extraWarnings.Count -gt 0) {
    Write-Host " / " -NoNewline
    Write-Host "$($extraWarnings.Count) warnings" -ForegroundColor Yellow -NoNewline
}
if ($extraSkipped.Count -gt 0) {
    Write-Host " / " -NoNewline
    Write-Host "$($extraSkipped.Count) skipped (needs elevation to check)" -ForegroundColor Yellow -NoNewline
}
Write-Host ""
Write-Host ""

if (-not $isAdmin) {
    Write-Host "Note: This session was not run as Administrator. Cannot check for .NET 3.5 without elevation." -ForegroundColor Yellow
    Write-Host ""
}

# ===========================================================================
# PART 13 - Export all results to a PDF report (via headless Microsoft Edge)
# ===========================================================================
# Builds an HTML version of everything shown in the console above, then
# renders it to PDF using Microsoft Edge's built-in headless "print to PDF"
# feature. No extra PowerShell modules, no Office/Word, no third-party PDF
# libraries required - just Edge, which ships by default on Windows 10
# 1809+ and all Windows 11 builds.
#
# Output: C:\hilb\HOSTNAME_build_report.pdf (HOSTNAME is the device's
# actual computer name). The destination folder is created automatically
# if it doesn't exist. A temporary HTML file is written alongside it and
# then removed.

function ConvertTo-SafeHtml {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-EdgePath {
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -Path $c)) { return $c }
    }
    $onPath = Get-Command -Name "msedge.exe" -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Export-BuildReportPdf {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [string]$Path = "C:\hilb\$($env:COMPUTERNAME)_build_report.pdf"
    )

    $edgePath = Get-EdgePath
    if (-not $edgePath) {
        Write-Host "Microsoft Edge not found - cannot render PDF. Skipping PDF export." -ForegroundColor Yellow
        return
    }

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    # --- Build the HTML report body -----------------------------------
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<html><head><meta charset='utf-8'><style>")
    [void]$sb.AppendLine("body { font-family: Consolas, 'Courier New', monospace; font-size: 11pt; margin: 24px; }")
    [void]$sb.AppendLine("h1 { font-size: 16pt; color: #0b5394; margin-bottom: 4px; }")
    [void]$sb.AppendLine("h2 { font-size: 13pt; color: #0b5394; margin-top: 22px; border-bottom: 1px solid #ccc; }")
    [void]$sb.AppendLine(".ok { color: #1a7f37; }")
    [void]$sb.AppendLine(".issue { color: #c62828; }")
    [void]$sb.AppendLine(".skipped { color: #a67c00; }")
    [void]$sb.AppendLine(".appname { color: #000000; }")
    [void]$sb.AppendLine(".line { margin: 3px 0; white-space: pre-wrap; }")
    [void]$sb.AppendLine(".meta { color: #555; font-size: 9pt; margin-bottom: 10px; }")
    [void]$sb.AppendLine("</style></head><body>")

    $reportTitle = "Build Report - $($env:COMPUTERNAME)"
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [void]$sb.AppendLine("<h1>$(ConvertTo-SafeHtml $reportTitle)</h1>")
    [void]$sb.AppendLine("<div class='meta'>Generated: $(ConvertTo-SafeHtml $generatedAt)</div>")

    [void]$sb.AppendLine("<h2>Application Installation Status</h2>")
    # Reuses the same $appLines array the console already built and sorted
    # alphabetically, so the PDF always matches the console exactly.
    foreach ($appLine in $appLines) {
        if ($appLine.Installed) {
            [void]$sb.AppendLine("<div class='line'><span class='ok'>[INSTALLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $appLine.NameText)  |  Version: $(ConvertTo-SafeHtml $appLine.VersionText)</span></div>")
        }
        else {
            [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $appLine.NameText)  |  Not found on this system</span></div>")
        }
    }

    [void]$sb.AppendLine("<h2>Additional System Checks</h2>")
    # Reuses the same $additionalChecksDisplay array the console already
    # built and sorted alphabetically, so the PDF always matches the console.
    foreach ($entry in $additionalChecksDisplay) {
        [void]$sb.AppendLine("<div class='line'><span class='$($entry.StatusClass)'>$(ConvertTo-SafeHtml $entry.Tag)</span> <span class='appname'>$(ConvertTo-SafeHtml $entry.Body)</span></div>")
    }

    # Local Admin Account
    [void]$sb.AppendLine("<h2>Local Admin Account</h2>")
    if (-not $localAdminResult.Ran) {
        [void]$sb.AppendLine("<div class='line'><span class='skipped'>[SKIPPED]</span> <span class='appname'>$(ConvertTo-SafeHtml $localAdminResult.Detail)</span></div>")
    }
    elseif ($localAdminResult.Success) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $localAdminResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[ISSUE]</span> <span class='appname'>$(ConvertTo-SafeHtml $localAdminResult.Detail)</span></div>")
    }

    # WinGet - Apply Updates
    [void]$sb.AppendLine("<h2>WinGet - Apply Updates</h2>")
    if (-not $allChecksPassed -or -not $wingetUpgradeResult.Ran) {
        [void]$sb.AppendLine("<div class='line'><span class='skipped'>[SKIPPED]</span> <span class='appname'>$(ConvertTo-SafeHtml $wingetUpgradeResult.Detail)</span></div>")
    }
    elseif ($wingetUpgradeResult.Success) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $wingetUpgradeResult.Detail)</span></div>")
        foreach ($updatedName in $wingetUpgradeResult.PendingNames) {
            [void]$sb.AppendLine("<div class='line'><span class='appname'>&nbsp;&nbsp;&nbsp;&nbsp;- $(ConvertTo-SafeHtml $updatedName)</span></div>")
        }
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[ISSUE]</span> <span class='appname'>$(ConvertTo-SafeHtml $wingetUpgradeResult.Detail)</span></div>")
        foreach ($updatedName in $wingetUpgradeResult.PendingNames) {
            [void]$sb.AppendLine("<div class='line'><span class='appname'>&nbsp;&nbsp;&nbsp;&nbsp;- $(ConvertTo-SafeHtml $updatedName)</span></div>")
        }
    }

    # Dell Command | Update - Apply Updates
    [void]$sb.AppendLine("<h2>Dell Command | Update - Apply Updates</h2>")
    if (-not $allChecksPassed -or -not $dcuApplyResult.Ran) {
        [void]$sb.AppendLine("<div class='line'><span class='skipped'>[SKIPPED]</span> <span class='appname'>$(ConvertTo-SafeHtml $dcuApplyResult.Detail)</span></div>")
    }
    elseif ($dcuApplyResult.Success) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $dcuApplyResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[ISSUE]</span> <span class='appname'>$(ConvertTo-SafeHtml $dcuApplyResult.Detail) (exit code $(ConvertTo-SafeHtml $dcuApplyResult.ExitCode))</span></div>")
    }

    # Hostname Status - shows the current hostname, or what it will become
    # after restart if it was renamed during this run.
    [void]$sb.AppendLine("<h2>Hostname Status</h2>")
    [void]$sb.AppendLine("<div class='line'><span class='appname'>$(ConvertTo-SafeHtml $finalHostnameStatus)</span></div>")

    # Summary (printed last, at the bottom of the PDF)
    [void]$sb.AppendLine("<h2>Summary</h2>")
    [void]$sb.AppendLine("<div class='line'><span class='ok'>$installedCount apps installed</span> / <span class='issue'>$missingCount apps missing</span>&nbsp;&nbsp;|&nbsp;&nbsp;<span class='ok'>$($extraOk.Count) extra checks OK</span> / <span class='issue'>$($extraIssues.Count) extra checks need attention</span>$(if ($extraWarnings.Count -gt 0) { " / <span class='skipped'>$($extraWarnings.Count) warnings</span>" })$(if ($extraSkipped.Count -gt 0) { " / <span class='skipped'>$($extraSkipped.Count) skipped (needs elevation to check)</span>" })</div>")

    [void]$sb.AppendLine("</body></html>")

    $htmlPath = [System.IO.Path]::ChangeExtension($Path, ".html")
    Set-Content -Path $htmlPath -Value $sb.ToString() -Encoding UTF8

    # --- Render HTML to PDF via headless Edge --------------------------
    $edgeArgs = @(
        "--headless",
        "--disable-gpu",
        "--no-margins",
        "--print-to-pdf=`"$Path`"",
        "`"$htmlPath`""
    )

    try {
        $proc = Start-Process -FilePath $edgePath -ArgumentList $edgeArgs -Wait -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 1   # Edge can return slightly before the file is flushed to disk
        if (Test-Path -Path $Path) {
            Write-Host "Build report exported to: $Path" -ForegroundColor Cyan
        }
        else {
            Write-Host "PDF export did not produce a file at $Path (Edge exit code: $($proc.ExitCode))." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "PDF export failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    finally {
        Remove-Item -Path $htmlPath -ErrorAction SilentlyContinue
    }
}

if ($Mode -eq 2) {
    Export-BuildReportPdf -Results $results

    if ($shouldReboot) {
        Write-Host "Rebooting in 20 seconds to finalize changes ($finalHostnameStatus)." -ForegroundColor Yellow
        Write-Host "A Windows shutdown notice will appear - the tech can cancel it with 'shutdown /a' if needed." -ForegroundColor Yellow
        shutdown.exe /r /t 20 /c "Hilb Group build script: rebooting to finalize changes ($finalHostnameStatus). Run 'shutdown /a' to cancel."
    }
    else {
        Write-Host "No updates were applied and the hostname was not changed - no reboot needed." -ForegroundColor Cyan
    }
}
else {
    # Quick check (Option 1): list what WinGet has available, but never
    # apply anything here - that only happens in Option 2.
    if ($wingetResult.Installed) {
        Write-Host "Checking WinGet for available app updates (listing only - not applying)..." -ForegroundColor Cyan
        $wingetPendingNamesQuick = Get-WingetPendingUpgradeNames

        if ($wingetPendingNamesQuick -and $wingetPendingNamesQuick.Count -gt 0) {
            Write-Host "[AVAILABLE] " -ForegroundColor Yellow -NoNewline
            Write-Host "WinGet updates available:" -ForegroundColor White -BackgroundColor Black
            foreach ($pendingNameQuick in $wingetPendingNamesQuick) {
                Write-Host "            - $pendingNameQuick" -ForegroundColor White -BackgroundColor Black
            }
        }
        else {
            Write-Host "[OK]        " -ForegroundColor Green -NoNewline
            Write-Host "No WinGet updates available - everything is already up to date." -ForegroundColor White -BackgroundColor Black
        }
        Write-Host ""
    }

    Write-Host "Quick software check complete - no PDF generated (run Option 2 for the full verification and PDF report)." -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# OPTIONAL / DISABLED - CSV export (kept as a fallback in case PDF rendering
# via Edge isn't available on a given machine). Uncomment both the function
# and the call below to also/instead export a CSV.
# ---------------------------------------------------------------------------
# function Export-BuildReport {
#     param(
#         [Parameter(Mandatory = $true)]
#         [object[]]$Results,
#
#         [string]$Path = "C:\hilb\$($env:COMPUTERNAME)_build_report.csv"
#     )
#
#     $folder = Split-Path -Path $Path -Parent
#     if ($folder -and -not (Test-Path -Path $folder)) {
#         New-Item -ItemType Directory -Path $folder -Force | Out-Null
#     }
#
#     $Results | Export-Csv -Path $Path -NoTypeInformation
#     Write-Host "Build report exported to: $Path" -ForegroundColor Cyan
# }
#
# Export-BuildReport -Results $results
