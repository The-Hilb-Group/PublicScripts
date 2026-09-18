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

    Part 6: Checks whether the WiFi profile "HILB-WiFI" is present on the
    machine (via netsh wlan show profiles). Reports green if found, red if
    not.

    Part 7: Checks whether the Microsoft Store app package is present.

    Part 8: Checks whether Snipping Tool is present (modern package or the
    legacy System32 executable).

    Part 9: Exports all results (apps + all extra checks) to a fixed CSV
    path, C:\hilb\HOSTNAME_build_report.csv (HOSTNAME replaced with the
    device's actual hostname), in addition to the console output.

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
    - Part 9 writes a CSV report to C:\hilb\HOSTNAME_build_report.csv on
      every run (HOSTNAME is the device's actual computer name); the
      destination folder is created automatically if it doesn't exist.
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
    $netFxAction = "Unable to query feature state - this usually requires an elevated session: $($_.Exception.Message)"
}

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
    CheckType    = '.NET 3.5'
    RequestedApp = '.NET Framework 3.5 (NetFx3)'
    Installed    = $netFxOk
    Skipped      = $netFxQueryFailed
    DisplayName  = "State: $netFxState"
    Version      = $null
    Detail       = $netFxAction
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
# PART 6 - Required WiFi profile "HILB-WiFI"
# ===========================================================================
$wifiProfileName = "HILB-WiFI"
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
# PART 7 - Microsoft Store presence
# ===========================================================================
$msStorePkg       = $null
$msStoreInstalled = $false
$msStoreVersion   = $null

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

$msStoreResult = [PSCustomObject]@{
    CheckType    = 'MS Store'
    RequestedApp = 'Microsoft Store'
    Installed    = $msStoreInstalled
    DisplayName  = $null
    Version      = $msStoreVersion
    Detail       = if (-not $msStoreInstalled) { "Microsoft.WindowsStore package not found for current user" } else { $null }
}

# ===========================================================================
# PART 8 - Snipping Tool presence (modern package or legacy exe)
# ===========================================================================
$snipPkg         = $null
$snipExePath     = Join-Path -Path $env:WINDIR -ChildPath "System32\SnippingTool.exe"
$snipInstalled   = $false
$snipVersion     = $null
$snipSource      = $null

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

$snipResult = [PSCustomObject]@{
    CheckType    = 'Snipping Tool'
    RequestedApp = 'Snipping Tool'
    Installed    = $snipInstalled
    DisplayName  = $snipSource
    Version      = $snipVersion
    Detail       = if (-not $snipInstalled) { "Not found (checked modern package and legacy System32 exe)" } else { $null }
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

foreach ($group in $grouped) {
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
        $nameText = if ($entry.DisplayName -eq $entry.RequestedApp) {
            $displayRequestedName
        }
        else {
            "$displayRequestedName -> $($entry.DisplayName)"
        }
        Write-Host "[INSTALLED] " -ForegroundColor Green -NoNewline
        Write-Host "$nameText  |  Version: $versionText" -ForegroundColor Green
    }
    else {
        $displayMissingName = if ($FriendlyNames.ContainsKey($group.Name)) {
            $FriendlyNames[$group.Name]
        }
        else {
            $group.Name
        }
        Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
        Write-Host "$displayMissingName  |  Not found on this system" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Additional System Checks" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Chocolatey
if ($chocoResult.Installed) {
    Write-Host "[INSTALLED] " -ForegroundColor Green -NoNewline
    Write-Host "$($chocoResult.RequestedApp) -> $($chocoResult.DisplayName)  |  Version: $($chocoResult.Version)" -ForegroundColor Green
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($chocoResult.RequestedApp)  |  $($chocoResult.Detail)" -ForegroundColor Red
}

# .NET 3.5
if ($netFxResult.Skipped) {
    Write-Host "[SKIPPED]   " -ForegroundColor Yellow -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor Yellow
}
elseif ($netFxResult.Installed) {
    Write-Host "[ENABLED]   " -ForegroundColor Green -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor Green
}
else {
    Write-Host "[DISABLED]  " -ForegroundColor Red -NoNewline
    $line = "$($netFxResult.RequestedApp)  |  $($netFxResult.DisplayName)"
    if ($netFxResult.Detail) { $line += "  |  $($netFxResult.Detail)" }
    Write-Host $line -ForegroundColor Red
}

# Registry key
if ($regResult.Installed) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($regResult.RequestedApp)  |  $($regResult.Detail)" -ForegroundColor Green
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($regResult.RequestedApp)  |  $($regResult.Detail)" -ForegroundColor Red
}

# Hostname naming convention
if ($hostnameResult.Installed) {
    Write-Host "[OK]        " -ForegroundColor Green -NoNewline
    Write-Host "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" -ForegroundColor Green
}
else {
    Write-Host "[ISSUE]     " -ForegroundColor Red -NoNewline
    Write-Host "$($hostnameResult.RequestedApp)  |  $($hostnameResult.DisplayName)  |  $($hostnameResult.Detail)" -ForegroundColor Red
}

# WiFi profile
if ($wifiResult.Installed) {
    Write-Host "[FOUND]     " -ForegroundColor Green -NoNewline
    Write-Host "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" -ForegroundColor Green
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($wifiResult.RequestedApp)  |  $($wifiResult.Detail)" -ForegroundColor Red
}

# Microsoft Store
if ($msStoreResult.Installed) {
    Write-Host "[INSTALLED] " -ForegroundColor Green -NoNewline
    $line = "$($msStoreResult.RequestedApp)"
    if ($msStoreResult.Version) { $line += "  |  Version: $($msStoreResult.Version)" }
    Write-Host $line -ForegroundColor Green
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($msStoreResult.RequestedApp)  |  $($msStoreResult.Detail)" -ForegroundColor Red
}

# Snipping Tool
if ($snipResult.Installed) {
    Write-Host "[INSTALLED] " -ForegroundColor Green -NoNewline
    $line = "$($snipResult.RequestedApp)"
    if ($snipResult.DisplayName) { $line += "  |  $($snipResult.DisplayName)" }
    if ($snipResult.Version)     { $line += "  |  Version: $($snipResult.Version)" }
    Write-Host $line -ForegroundColor Green
}
else {
    Write-Host "[MISSING]   " -ForegroundColor Red -NoNewline
    Write-Host "$($snipResult.RequestedApp)  |  $($snipResult.Detail)" -ForegroundColor Red
}

Write-Host ""

# ===========================================================================
# Summary
# ===========================================================================
$installedCount = ($grouped | Where-Object { $_.Group[0].Installed }).Count
$missingCount    = ($grouped | Where-Object { -not $_.Group[0].Installed }).Count
$extraChecks     = @($chocoResult, $netFxResult, $regResult, $hostnameResult, $wifiResult, $msStoreResult, $snipResult)
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
# PART 9 - Export all results to a fixed CSV path
# ===========================================================================
# Exports the full $results set (apps + all extra checks) to
# C:\hilb\HOSTNAME_build_report.csv (HOSTNAME is the device's actual
# computer name), in addition to the console output above.
function Export-BuildReport {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [string]$Path = "C:\hilb\$($env:COMPUTERNAME)_build_report.csv"
    )

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $Results | Export-Csv -Path $Path -NoTypeInformation
    Write-Host "Build report exported to: $Path" -ForegroundColor Cyan
}

Export-BuildReport -Results $results