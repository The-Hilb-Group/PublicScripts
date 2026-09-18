<#
.SYNOPSIS
    Checks installation status and version number for a list of applications,
    plus Chocolatey presence, .NET Framework 3.5 status, an IPv6 registry
    configuration, hostname naming convention, a required WiFi profile, and
    presence of the Microsoft Store and Snipping Tool.

.DESCRIPTION
    Part 1: Searches the standard Windows registry uninstall locations
    (64-bit, 32-bit/WOW6432Node, and per-user) for each application name in
    $AppList, using partial ("contains") matching on the display name.

    Part 2: Checks for choco.exe under C:\ProgramData\chocolatey\ and reports
    its version if present.

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

    Part 9: Exports all results (apps + all extra checks) to a PDF report at
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
    - Part 9 writes a PDF report to C:\hilb\HOSTNAME_build_report.pdf on
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

    [string]$CsvPath
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
    "Dialpad Machine-Wide Installer"
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
    "Dialpad Machine-Wide Installer" = "Dialpad"
    "Dell Command | Update for Windows Universal" = "Dell Command | Update"
}

# ---------------------------------------------------------------------------
# Are we elevated? (Needed for the .NET 3.5 enable step)
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

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

Write-Verbose "Enumerating installed applications from registry..."

$installed = foreach ($keyPath in $uninstallKeys) {
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
$installed = $installed | Sort-Object DisplayName, DisplayVersion -Unique

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

# ===========================================================================
# PART 2 - Chocolatey presence and version
# ===========================================================================
$chocoPath = "C:\ProgramData\chocolatey\choco.exe"
$chocoResult = if (Test-Path -Path $chocoPath) {
    $chocoVersion = $null
    try {
        $chocoVersion = (Get-Item -Path $chocoPath).VersionInfo.ProductVersion
    }
    catch {
        $chocoVersion = "(version unknown)"
    }
    [PSCustomObject]@{
        CheckType    = 'Chocolatey'
        RequestedApp = 'Chocolatey (choco.exe)'
        Installed    = $true
        DisplayName  = $chocoPath
        Version      = $chocoVersion
        Detail       = $null
    }
}
else {
    [PSCustomObject]@{
        CheckType    = 'Chocolatey'
        RequestedApp = 'Chocolatey (choco.exe)'
        Installed    = $false
        DisplayName  = $null
        Version      = $null
        Detail       = "Not found at $chocoPath"
    }
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
    $netFxAction = "Unable to query feature state: $($_.Exception.Message)"
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
    RequestedApp        = '.NET Framework 3.5 (NetFx3)'
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
    RequestedApp = "$regName @ Tcpip6\Parameters"
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
    DisplayName  = "Hostname: $hostnameValue"
    Version      = $null
    Detail       = if ($hostnameOk) { "Does not contain 'SD-'" } else { "Contains 'SD-' - naming convention violation" }
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
# Combine all results
# ===========================================================================
$results = @($appResults) + @($chocoResult) + @($netFxResult) + @($regResult) + `
           @($hostnameResult) + @($wifiResult) + @($msStoreResult) + @($snipResult)

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

# Chocolatey is a genuine installed application, but it doesn't register an
# uninstall entry in the registry/Control Panel like the apps above, so it's
# checked separately (Part 2) - fold its result into the same app list here
# so it reports and aligns alongside everything else.
$appLines += [PSCustomObject]@{
    Installed   = $chocoResult.Installed
    NameText    = $chocoResult.RequestedApp
    VersionText = $chocoResult.Version
}

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

# .NET 3.5
if ($netFxResult.Skipped) {
    Write-Host "[SKIPPED]   " -ForegroundColor Yellow -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
elseif ($netFxResult.Installed -and $netFxResult.WasAlreadyEnabled) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
elseif ($netFxResult.Installed) {
    Write-Host "[ENABLED]   " -ForegroundColor Green -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[DISABLED]  " -ForegroundColor Red -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}

# Registry key
if ($regResult.Installed) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($regResult.RequestedApp)  |  $($regResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($regResult.RequestedApp)  |  $($regResult.Detail)" -ForegroundColor White -BackgroundColor Black
}

# Hostname naming convention
if ($hostnameResult.Installed) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" -ForegroundColor White -BackgroundColor Black
}

# WiFi profile
if ($wifiResult.Installed) {
    Write-Host "[FOUND]     " -ForegroundColor Green -NoNewline
    Write-Host "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" -ForegroundColor White -BackgroundColor Black
}

# Microsoft Store
if ($msStoreResult.Installed -and $msStoreResult.WasAlreadyEnabled) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    $line = "$($msStoreResult.RequestedApp)"
    if ($msStoreResult.Version) { $line += "  |  Version: $($msStoreResult.Version)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
elseif ($msStoreResult.Installed) {
    Write-Host "[ENABLED]   " -ForegroundColor Green -NoNewline
    $line = "$($msStoreResult.RequestedApp)"
    if ($msStoreResult.Version) { $line += "  |  Version: $($msStoreResult.Version)" }
    if ($msStoreResult.Detail)  { $line += "  |  $($msStoreResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($msStoreResult.RequestedApp)  |  $($msStoreResult.Detail)" -ForegroundColor White -BackgroundColor Black
}

# Snipping Tool
if ($snipResult.Installed -and $snipResult.WasAlreadyEnabled) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    $line = "$($snipResult.RequestedApp)"
    if ($snipResult.DisplayName) { $line += "  |  $($snipResult.DisplayName)" }
    if ($snipResult.Version)     { $line += "  |  Version: $($snipResult.Version)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
elseif ($snipResult.Installed) {
    Write-Host "[ENABLED]   " -ForegroundColor Green -NoNewline
    $line = "$($snipResult.RequestedApp)"
    if ($snipResult.DisplayName) { $line += "  |  $($snipResult.DisplayName)" }
    if ($snipResult.Version)     { $line += "  |  Version: $($snipResult.Version)" }
    if ($snipResult.Detail)      { $line += "  |  $($snipResult.Detail)" }
    Write-Host $line -ForegroundColor White -BackgroundColor Black
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($snipResult.RequestedApp)  |  $($snipResult.Detail)" -ForegroundColor White -BackgroundColor Black
}

Write-Host ""

# ===========================================================================
# Summary
# ===========================================================================
$installedCount = ($appLines | Where-Object { $_.Installed }).Count
$missingCount    = ($appLines | Where-Object { -not $_.Installed }).Count
$extraChecks     = @($netFxResult, $regResult, $hostnameResult, $wifiResult, $msStoreResult, $snipResult)
$extraSkipped    = $extraChecks | Where-Object { $_.Skipped -eq $true }
$extraOk         = $extraChecks | Where-Object { -not $_.Skipped -and $_.Installed }
$extraIssues     = $extraChecks | Where-Object { -not $_.Skipped -and -not $_.Installed }

Write-Host "Summary: " -NoNewline
Write-Host "$installedCount apps installed" -ForegroundColor Green -NoNewline
Write-Host " / " -NoNewline
Write-Host "$missingCount apps missing" -ForegroundColor Red -NoNewline
Write-Host "   |   " -NoNewline
Write-Host "$($extraOk.Count) extra checks OK" -ForegroundColor Green -NoNewline
Write-Host " / " -NoNewline
Write-Host "$($extraIssues.Count) extra checks need attention" -ForegroundColor Red -NoNewline
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
# PART 9 - Export all results to a PDF report (via headless Microsoft Edge)
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
    foreach ($group in $grouped) {
        $entries = $group.Group
        if ($entries[0].Installed) {
            $entry = $entries | Sort-Object { ($_.Version | Out-String).Trim().Length } -Descending | Select-Object -First 1
            $displayRequestedName = if ($FriendlyNames.ContainsKey($entry.RequestedApp)) { $FriendlyNames[$entry.RequestedApp] } else { $entry.RequestedApp }
            $versionText = if ($entry.Version) { $entry.Version } else { "(version unknown)" }
            $nameText = if ($entry.DisplayName -eq $entry.RequestedApp -or $entry.DisplayName.StartsWith($entry.RequestedApp, [System.StringComparison]::OrdinalIgnoreCase)) { $displayRequestedName } else { "$displayRequestedName -> $($entry.DisplayName)" }
            [void]$sb.AppendLine("<div class='line'><span class='ok'>[INSTALLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $nameText)  |  Version: $(ConvertTo-SafeHtml $versionText)</span></div>")
        }
        else {
            $displayMissingName = if ($FriendlyNames.ContainsKey($group.Name)) { $FriendlyNames[$group.Name] } else { $group.Name }
            [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $displayMissingName)  |  Not found on this system</span></div>")
        }
    }

    # Chocolatey doesn't register an uninstall entry like the apps above, but
    # it's a genuine installed application - report it alongside them here.
    if ($chocoResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[INSTALLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $chocoResult.RequestedApp)  |  Version: $(ConvertTo-SafeHtml $chocoResult.Version)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $chocoResult.RequestedApp)  |  Not found on this system</span></div>")
    }

    [void]$sb.AppendLine("<h2>Additional System Checks</h2>")

    # .NET 3.5
    if ($netFxResult.Skipped) {
        [void]$sb.AppendLine("<div class='line'><span class='skipped'>[SKIPPED]</span> <span class='appname'>$(ConvertTo-SafeHtml $netFxResult.RequestedApp)  |  $(ConvertTo-SafeHtml $netFxResult.DisplayName)  |  $(ConvertTo-SafeHtml $netFxResult.Detail)</span></div>")
    }
    elseif ($netFxResult.Installed -and $netFxResult.WasAlreadyEnabled) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $netFxResult.RequestedApp)  |  $(ConvertTo-SafeHtml $netFxResult.DisplayName)  |  $(ConvertTo-SafeHtml $netFxResult.Detail)</span></div>")
    }
    elseif ($netFxResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[ENABLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $netFxResult.RequestedApp)  |  $(ConvertTo-SafeHtml $netFxResult.DisplayName)  |  $(ConvertTo-SafeHtml $netFxResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[DISABLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $netFxResult.RequestedApp)  |  $(ConvertTo-SafeHtml $netFxResult.DisplayName)  |  $(ConvertTo-SafeHtml $netFxResult.Detail)</span></div>")
    }

    # Registry key
    if ($regResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $regResult.RequestedApp)  |  $(ConvertTo-SafeHtml $regResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[ISSUE]</span> <span class='appname'>$(ConvertTo-SafeHtml $regResult.RequestedApp)  |  $(ConvertTo-SafeHtml $regResult.Detail)</span></div>")
    }

    # Hostname naming convention
    if ($hostnameResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $hostnameResult.RequestedApp)  |  $(ConvertTo-SafeHtml $hostnameResult.DisplayName)  |  $(ConvertTo-SafeHtml $hostnameResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[ISSUE]</span> <span class='appname'>$(ConvertTo-SafeHtml $hostnameResult.RequestedApp)  |  $(ConvertTo-SafeHtml $hostnameResult.DisplayName)  |  $(ConvertTo-SafeHtml $hostnameResult.Detail)</span></div>")
    }

    # WiFi profile
    if ($wifiResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[FOUND]</span> <span class='appname'>$(ConvertTo-SafeHtml $wifiResult.RequestedApp)  |  $(ConvertTo-SafeHtml $wifiResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $wifiResult.RequestedApp)  |  $(ConvertTo-SafeHtml $wifiResult.Detail)</span></div>")
    }

    # Microsoft Store
    if ($msStoreResult.Installed -and $msStoreResult.WasAlreadyEnabled) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $msStoreResult.RequestedApp)  |  Version: $(ConvertTo-SafeHtml $msStoreResult.Version)</span></div>")
    }
    elseif ($msStoreResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[ENABLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $msStoreResult.RequestedApp)  |  Version: $(ConvertTo-SafeHtml $msStoreResult.Version)  |  $(ConvertTo-SafeHtml $msStoreResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $msStoreResult.RequestedApp)  |  $(ConvertTo-SafeHtml $msStoreResult.Detail)</span></div>")
    }

    # Snipping Tool
    if ($snipResult.Installed -and $snipResult.WasAlreadyEnabled) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[OK]</span> <span class='appname'>$(ConvertTo-SafeHtml $snipResult.RequestedApp)  |  $(ConvertTo-SafeHtml $snipResult.DisplayName)  |  Version: $(ConvertTo-SafeHtml $snipResult.Version)</span></div>")
    }
    elseif ($snipResult.Installed) {
        [void]$sb.AppendLine("<div class='line'><span class='ok'>[ENABLED]</span> <span class='appname'>$(ConvertTo-SafeHtml $snipResult.RequestedApp)  |  $(ConvertTo-SafeHtml $snipResult.DisplayName)  |  Version: $(ConvertTo-SafeHtml $snipResult.Version)  |  $(ConvertTo-SafeHtml $snipResult.Detail)</span></div>")
    }
    else {
        [void]$sb.AppendLine("<div class='line'><span class='issue'>[MISSING]</span> <span class='appname'>$(ConvertTo-SafeHtml $snipResult.RequestedApp)  |  $(ConvertTo-SafeHtml $snipResult.Detail)</span></div>")
    }

    # Summary
    [void]$sb.AppendLine("<h2>Summary</h2>")
    [void]$sb.AppendLine("<div class='line'><span class='ok'>$installedCount apps installed</span> / <span class='issue'>$missingCount apps missing</span>&nbsp;&nbsp;|&nbsp;&nbsp;<span class='ok'>$($extraOk.Count) extra checks OK</span> / <span class='issue'>$($extraIssues.Count) extra checks need attention</span>$(if ($extraSkipped.Count -gt 0) { " / <span class='skipped'>$($extraSkipped.Count) skipped (needs elevation to check)</span>" })</div>")

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

Export-BuildReportPdf -Results $results

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
