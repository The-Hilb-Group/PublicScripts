<#
.SYNOPSIS
    Finds the latest ImageRight patches (.msp) on the release notes page,
    checks this machine first, then downloads, installs, verifies, and cleans up
    only what is actually needed.

.DESCRIPTION
    Every patch prefix is paired with the Programs and Features display name of
    the app it patches:
      - Required : expected on every machine. A missing base app is unexpected,
                   so it is logged as a warning and the patch is skipped.
      - Optional : only needed when the base app is installed; skipped quietly if not.

    Flow:
      1. Discover  - read the release notes page and find the latest patch + .msp link
      2. Check     - confirm the base app is installed and the patch isn't already
                     applied in Windows (by patch code, once it's in the cache)
      3. Download  - BITS-download only the patches that are still needed
      4. Install   - re-check by patch code from the .msp itself, then apply it
      5. Verify    - confirm Windows Installer shows the patch as applied
      6. Clean up  - remove .msp files that are no longer needed

    Every run writes a timestamped log to $LogPath, and each install also gets
    its own verbose msiexec log in the same folder.

.EXAMPLE
    .\Get-ImageRightLatestPatches.ps1                      # full run
    .\Get-ImageRightLatestPatches.ps1 -DownloadOnly        # check + stage files, no install
    .\Get-ImageRightLatestPatches.ps1 -KeepDownloads       # install but keep files
    .\Get-ImageRightLatestPatches.ps1 -Verbose -Force

.NOTES
    Windows PowerShell 5.1 or PowerShell 7+ on Windows. Installing requires
    an elevated session. The script never reboots; it reports when one is needed.

    Exit codes: 0 = success, 3010 = success but reboot required, 1 = one or more failures.
#>

[CmdletBinding()]
param(
    [string]$Url = 'https://help.vertafore.com/imagerightbrowserclient/content/releasenotes_25r1.htm',

    # Patch prefix -> Programs and Features display name of the base app.
    # Always expected to be installed. Processed in this order.
    # Wildcards are allowed in the display name (e.g. 'ImageRight Desktop*').
    [System.Collections.IDictionary]$RequiredApps = [ordered]@{
        'FrontEnd.Patch'         = 'ImageRight Front End Integration'
        'IRMicrosoftAddIn.Patch' = 'ImageRight Microsoft Add In'
        'IRConnect.Patch'        = 'ImageRight Connect'
        'IRDesktop.Patch'        = 'ImageRight Desktop'
        'IRAdobe.Patch'          = 'ImageRight Adobe Plug-In'
        'IRBrowser.Patch'        = 'ImageRight Browser Plug-in'
    },

    # Patch prefix -> base app display name. Only patched if the base app is installed.
    [System.Collections.IDictionary]$OptionalApps = [ordered]@{
        'IRWFStudio.Patch' = 'ImageRight Workflow Studio'
        'IRAdmin.Patch'    = 'Imageright Enterprise Management Console'
        'IRScanner.Patch'  = 'ImageRight Scanner'
    },

    # Patch prefix -> base name the patch registers under in Windows ("View installed updates").
    # Windows shows "<base name> <version>", e.g. "ImageRight Desktop Patch 25.1.1.233";
    # the version is taken from the patch file name on the release notes page.
    # Mapped patches can be detected before download, even on a machine's first run.
    [System.Collections.IDictionary]$PatchDisplayNames = [ordered]@{
        'FrontEnd.Patch'         = 'ImageRight Front End Integration Patch'
        'IRMicrosoftAddIn.Patch' = 'ImageRight Microsoft Add In Patch'
        'IRConnect.Patch'        = 'ImageRight Connect Patch'
        'IRDesktop.Patch'        = 'ImageRight Desktop Patch'
    },

    # Remembers each patch file's patch code so later runs can check Windows
    # for that exact patch before downloading. Can point to a shared location.
    [string]$PatchCachePath = 'C:\temp\ImagerightPatchLogs\PatchCodeCache.json',

    [string]$Destination = 'C:\temp\IR_Patches',

    [string]$LogPath = 'C:\temp\ImagerightPatchLogs',

    # Re-download even if the file already exists in $Destination
    [switch]$Force,

    # Don't process the optional list at all
    [switch]$SkipOptional,

    # Download optional patches even if their base app isn't installed here
    # (installation is still skipped for those)
    [switch]$DownloadAllOptional,

    # Check and download only: skip install, verify, and cleanup
    [switch]$DownloadOnly,

    # Install and verify, but leave the downloaded files in place
    [switch]$KeepDownloads,

    # Seconds to wait before cleanup (and between retries) so file locks can clear
    [int]$CleanupDelaySeconds = 5,

    # How many times to try deleting a locked file before giving up
    [int]$CleanupRetries = 3
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module BitsTransfer -ErrorAction Stop
Add-Type -AssemblyName System.Web

# =============================================================================
#  Logging
# =============================================================================
if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
$RunStamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:LogFile = Join-Path $LogPath "ImageRightPatch_${env:COMPUTERNAME}_$RunStamp.log"

function Write-Log {
    <# Writes a timestamped line to the run log and to the console. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'SKIP')][string]$Level = 'INFO'
    )

    $line = '{0} [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line

    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'SKIP'    { 'DarkGray' }
        default   { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
}

# =============================================================================
#  General helpers
# =============================================================================
function Get-NaturalSortKey {
    param([string]$Value)
    # Pad every run of digits so string sorting = numeric sorting ("10" > "9")
    [regex]::Replace($Value, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}

function ConvertTo-PlainText {
    param([string]$Html)
    [System.Web.HttpUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' '))
}

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
#  Installed-app detection (base apps)
# =============================================================================
function Get-InstalledApplication {
    <#
        Returns every entry from Programs and Features (64-bit, 32-bit, and
        per-user uninstall keys). Reads the registry directly instead of
        Win32_Product, which is slow and can trigger MSI repairs.
    #>
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, PSPath
}

function Test-AppInstalled {
    <#
        Returns the matching Programs and Features entry (or $null) for a
        display name. Matching is case-insensitive; wildcards are supported.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [object[]]$InstalledApps = (Get-InstalledApplication)
    )

    $InstalledApps |
        Where-Object { $_.DisplayName -like $DisplayName } |
        Select-Object -First 1
}

# =============================================================================
#  Pre-download patch checks
# =============================================================================
# Two ways to tell, before downloading, that a patch is already installed:
#   1. By name   - mapped patches register as "<base name> <version>", so the exact
#                  expected name is built from $PatchDisplayNames + the file's version.
#   2. By cache  - for unmapped patches, the patch code read from the MSP the first
#                  time it was downloaded, checked against Windows Installer.

function Get-PatchVersion {
    <# Pulls the version out of a patch name, e.g. IRDesktop.Patch.25.1.1.233.msp -> 25.1.1.233 #>
    param([Parameter(Mandatory)][string]$PatchName)
    $m = [regex]::Match($PatchName, '\d+(?:\.\d+)+')
    if ($m.Success) { $m.Value } else { $null }
}

function Get-ExpectedPatchName {
    <# Builds the name Windows should show for this patch, or $null if it isn't mapped. #>
    param([Parameter(Mandatory)][string]$Prefix, [Parameter(Mandatory)][string]$PatchName)

    $base    = $PatchDisplayNames[$Prefix]
    $version = Get-PatchVersion $PatchName
    if ($base -and $version) { "$base $version" } else { $null }
}

function Get-RegisteredPatch {
    <#
        Lists every patch Windows Installer has registered per-machine with its
        display name and state (1 = Applied, 2 = Superseded, 4 = Obsoleted).
        These are the entries shown under "View installed updates".
    #>
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\*\Patches\*'

    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        [pscustomobject]@{ DisplayName = $props.DisplayName; State = $props.State }
    } | Where-Object { $_.DisplayName }
}

function Find-RegisteredPatchByName {
    <# Returns the Applied/Superseded patch whose name exactly matches (case-insensitive), or $null. #>
    param([Parameter(Mandatory)][string]$DisplayName, [object[]]$RegisteredPatches)

    $RegisteredPatches |
        Where-Object { $_.DisplayName -eq $DisplayName -and $_.State -in 1, 2 } |
        Select-Object -First 1
}

function Get-PatchCacheKey {
    param([Parameter(Mandatory)][string]$PatchName)
    ($PatchName -replace '\.msp$', '').ToLowerInvariant()
}

function Get-PatchCache {
    <# Loads the cache as a hashtable: patch name -> PatchCode, TargetProducts, DisplayName. #>
    param([Parameter(Mandatory)][string]$Path)

    $cache = @{}
    if (Test-Path $Path) {
        try {
            $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                $cache[$p.Name] = [pscustomobject]@{
                    PatchCode      = $p.Value.PatchCode
                    TargetProducts = @($p.Value.TargetProducts)
                    DisplayName    = $p.Value.DisplayName
                }
            }
        }
        catch {
            Write-Log "Could not read patch cache $Path : $($_.Exception.Message)" -Level WARN
        }
    }
    return $cache
}

function Save-PatchCache {
    param([Parameter(Mandatory)][hashtable]$Cache, [Parameter(Mandatory)][string]$Path)

    try {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $Cache | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
        Write-Verbose "Saved patch cache to $Path"
    }
    catch {
        Write-Log "Could not save patch cache $Path : $($_.Exception.Message)" -Level WARN
    }
}

# =============================================================================
#  MSP / Windows Installer helpers (post-download checks)
# =============================================================================
function Invoke-ComMember {
    <# Late-bound COM call; the WindowsInstaller object needs this in Windows PowerShell 5.1. #>
    param($Object, [string]$Name, [System.Reflection.BindingFlags]$Kind, [object[]]$Arguments = @())
    $Object.GetType().InvokeMember($Name, $Kind, $null, $Object, $Arguments)
}

function ConvertTo-CompressedGuid {
    <# Converts {GUID} to the "packed" form Windows Installer uses for registry key names. #>
    param([Parameter(Mandatory)][string]$Guid)

    $g = $Guid.Trim('{}').Replace('-', '').ToUpper()
    $reverse = { param($s) -join ($s.ToCharArray()[($s.Length - 1)..0]) }

    $packed = (& $reverse $g.Substring(0, 8)) + (& $reverse $g.Substring(8, 4)) + (& $reverse $g.Substring(12, 4))
    for ($i = 16; $i -lt 32; $i += 2) { $packed += $g[$i + 1] + $g[$i] }
    $packed
}

function Get-MspInfo {
    <#
        Reads an .msp file and returns:
          PatchCode      - GUID Windows uses to track the patch
          TargetProducts - ProductCodes the patch can be applied to
          DisplayName    - friendly name from the patch metadata (if present)
    #>
    param([Parameter(Mandatory)][string]$Path)

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
    <# Returns the target ProductCodes that are installed per-machine on this computer. #>
    param([string[]]$ProductCodes)

    foreach ($code in $ProductCodes) {
        $packed = ConvertTo-CompressedGuid $code
        if (Test-Path "HKLM:\SOFTWARE\Classes\Installer\Products\$packed") { $code }
    }
}

function Get-MspInstallState {
    <#
        Checks Windows Installer's registration of a patch against each installed
        target product. State values: 1 = Applied, 2 = Superseded, 4 = Obsoleted.
        Returns one object per installed target product.
    #>
    param(
        [Parameter(Mandatory)][string]$PatchCode,
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
    <# $true if the patch is Applied (or Superseded by a newer one) on every installed target product. #>
    param([object[]]$States)
    [bool]($States -and -not ($States | Where-Object { $_.State -notin 'Applied', 'Superseded' }))
}

# =============================================================================
#  Install
# =============================================================================
function Install-ImageRightPatch {
    <# Applies one .msp silently with a verbose msiexec log. Returns the exit code. #>
    param(
        [Parameter(Mandatory)][string]$MspPath,
        [Parameter(Mandatory)][string]$LogDirectory
    )

    $baseName  = [IO.Path]::GetFileNameWithoutExtension($MspPath)
    $msiLog    = Join-Path $LogDirectory "${baseName}_$RunStamp.msi.log"
    $arguments = "/p `"$MspPath`" /qn /norestart /l*v `"$msiLog`""

    Write-Log "  Running: msiexec.exe $arguments"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Write-Log "  msiexec log: $msiLog"
    return $process.ExitCode
}

function Get-InstallOutcome {
    <# Translates common msiexec exit codes. #>
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

# =============================================================================
#  Cleanup
# =============================================================================
function Remove-PatchFile {
    <#
        Deletes downloaded .msp files for patches that installed successfully,
        were already installed, or don't apply to this machine. Failed patches
        are kept so they can be investigated.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$DownloadFolder,
        [int]$Retries = 3,
        [int]$DelaySeconds = 5
    )

    $removable = 'Already installed', 'Not applicable'

    foreach ($r in $Results) {
        if ($r.Install -notlike 'Installed*' -and $r.Install -notin $removable) { continue }
        if (-not $r.Path -or -not (Test-Path $r.Path)) { continue }

        for ($attempt = 1; $attempt -le $Retries; $attempt++) {
            try {
                Remove-Item -Path $r.Path -Force -ErrorAction Stop
                Write-Log "  Removed $($r.Path)"
                $r.Cleanup = 'Removed'
                break
            }
            catch {
                if ($attempt -lt $Retries) {
                    Write-Log "  $($r.Path) is locked (attempt $attempt of $Retries) - waiting $DelaySeconds seconds." -Level SKIP
                    Start-Sleep -Seconds $DelaySeconds
                }
                else {
                    Write-Log "  Could not remove $($r.Path) after $Retries attempts: $($_.Exception.Message)" -Level WARN
                    $r.Cleanup = 'Failed (locked)'
                }
            }
        }
    }

    # Remove the download folder itself if nothing is left in it
    if ((Test-Path $DownloadFolder) -and -not (Get-ChildItem -Path $DownloadFolder -Force)) {
        Remove-Item -Path $DownloadFolder -Force
        Write-Log "  Removed empty folder $DownloadFolder"
    }
}

# =============================================================================
#  Main
# =============================================================================
Write-Log "ImageRight patch run started on $env:COMPUTERNAME by $env:USERDOMAIN\$env:USERNAME"
Write-Log "Log file: $script:LogFile"

$isAdmin = Test-IsAdmin
if (-not $DownloadOnly -and -not $isAdmin) {
    Write-Log 'This session is not elevated. Patches will be checked and downloaded but NOT installed. Re-run as administrator to install.' -Level WARN
}

# --- Build the work list (blank entries ignored) ------------------------------
$workList = @()
foreach ($key in $RequiredApps.Keys) {
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $workList += [pscustomobject]@{ Prefix = $key; Category = 'Required'; BaseApp = $RequiredApps[$key] }
}
if (-not $SkipOptional) {
    foreach ($key in $OptionalApps.Keys) {
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $workList += [pscustomobject]@{ Prefix = $key; Category = 'Optional'; BaseApp = $OptionalApps[$key] }
    }
}

# Snapshot installed apps and registered patches once, and load the patch-code cache
$installedApps     = @(Get-InstalledApplication)
$registeredPatches = @(Get-RegisteredPatch)
$patchCache        = Get-PatchCache -Path $PatchCachePath
$cacheChanged      = $false
Write-Verbose "Found $($installedApps.Count) apps, $($registeredPatches.Count) registered patches, $($patchCache.Count) cached patch code(s)."

# --- Read the release notes page ----------------------------------------------
try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
    Write-Log "Downloaded release notes: $Url"
}
catch {
    Write-Log "Failed to download $Url : $($_.Exception.Message)" -Level ERROR
    exit 1
}

$pageText = ConvertTo-PlainText $response.Content
$baseUri  = [Uri]$Url

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

# --- Steps 1 & 2: discover latest patches and check this machine --------------
$currentCategory = $null
foreach ($item in $workList) {
    $prefix = $item.Prefix

    if ($item.Category -ne $currentCategory) {
        $currentCategory = $item.Category
        Write-Log ''
        Write-Log "=== Checking $currentCategory patches ==="
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
        Write-Log ("{0,-25} : no matches found on page" -f "$prefix*") -Level WARN
        $r.Check = 'Not found on page'
        continue
    }
    Write-Log ("{0,-25} : latest is {1}" -f "$prefix*", $r.Latest)
    Write-Verbose ("  All text matches: " + ($textMatches -join ', '))

    # Base app present?
    $app = Test-AppInstalled -DisplayName $item.BaseApp -InstalledApps $installedApps
    if ($app) {
        $r.BaseInstalled = $true
        $r.BaseVersion   = $app.DisplayVersion
        Write-Verbose "  Base app found: $($app.DisplayName) $($app.DisplayVersion)"
    }
    elseif ($item.Category -eq 'Required') {
        Write-Log "  Required base app '$($item.BaseApp)' is NOT installed - skipping this patch." -Level WARN
        $r.Check = 'Base app missing'
        continue
    }
    elseif (-not $DownloadAllOptional) {
        Write-Log "  '$($item.BaseApp)' not installed - skipping." -Level SKIP
        $r.Check = 'Base app not installed'
        continue
    }
    else {
        Write-Log "  '$($item.BaseApp)' not installed - downloading only (-DownloadAllOptional)." -Level SKIP
    }

    # Already installed? 1) exact "<name> <version>" registered in Windows
    $expectedName = Get-ExpectedPatchName -Prefix $prefix -PatchName $r.Latest
    if ($r.BaseInstalled -and $expectedName) {
        $existing = Find-RegisteredPatchByName -DisplayName $expectedName -RegisteredPatches $registeredPatches
        if ($existing) {
            $stateText = if ($existing.State -eq 2) { 'Superseded' } else { 'Applied' }
            Write-Log "  Already installed: '$($existing.DisplayName)' ($stateText) - no download needed." -Level SKIP
            $r.Check    = 'Already installed'
            $r.Install  = 'Already installed'
            $r.Verified = $true
            continue
        }
        Write-Verbose "  '$expectedName' not registered in Windows."
    }

    # Already installed? 2) exact patch code from the cache, checked against Windows
    $cached = $patchCache[(Get-PatchCacheKey $r.Latest)]
    if ($r.BaseInstalled -and $cached) {
        $r.PatchCode      = $cached.PatchCode
        $r.TargetProducts = @(Get-InstalledTargetProduct -ProductCodes $cached.TargetProducts)

        if (-not $r.TargetProducts) {
            Write-Log '  None of the products this patch targets are installed - no download needed.' -Level SKIP
            $r.Check   = 'Not applicable'
            $r.Install = 'Not applicable'
            continue
        }

        $states = @(Get-MspInstallState -PatchCode $r.PatchCode -InstalledProducts $r.TargetProducts)
        if (Test-MspApplied $states) {
            Write-Log "  Already installed ($(($states.State | Sort-Object -Unique) -join ', ')) - no download needed." -Level SKIP
            $r.Check    = 'Already installed'
            $r.Install  = 'Already installed'
            $r.Verified = $true
            continue
        }
        Write-Verbose "  Patch code $($r.PatchCode) is known but not applied - download needed."
    }
    elseif ($r.BaseInstalled) {
        Write-Verbose '  Patch not in cache yet - downloading to read its patch code.'
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
        Write-Log "  No .msp download link found on the page for $($r.Latest)." -Level WARN
        $r.Check = 'No link'
        continue
    }

    $r.Url   = $link.Url
    $r.Path  = Join-Path $Destination $link.FileName
    $r.Check = if ($r.BaseInstalled) { 'Needed' } else { 'Download only' }
    Write-Log "  Needed - will download $($link.FileName)" -Level SUCCESS
}

# --- Step 3: download what's needed -------------------------------------------
$toDownload = @($results | Where-Object { $_.Check -in 'Needed', 'Download only' })

Write-Log ''
Write-Log '=== Downloading patches ==='

if (-not $toDownload) {
    Write-Log 'Nothing to download - this machine is up to date.' -Level SUCCESS
}
else {
    if (-not (Test-Path $Destination)) { New-Item -Path $Destination -ItemType Directory -Force | Out-Null }

    foreach ($r in $toDownload) {
        $fileName = Split-Path $r.Path -Leaf

        if ((Test-Path $r.Path) -and -not $Force) {
            Write-Log "$fileName : already downloaded" -Level SKIP
            $r.Download = 'Already present'
            continue
        }

        Write-Log "$fileName : downloading $($r.Url)"
        try {
            Start-BitsTransfer -Source $r.Url -Destination $r.Path `
                -DisplayName "ImageRight patch: $fileName" `
                -Description "Downloading $fileName" -ErrorAction Stop
            Write-Log "  Saved to $($r.Path)" -Level SUCCESS
            $r.Download = 'Downloaded'
        }
        catch {
            Write-Log "  BITS transfer failed for $fileName : $($_.Exception.Message)" -Level ERROR
            $r.Download = 'Failed'
        }
    }
}

# --- Steps 4-6: install, verify, clean up --------------------------------------
$rebootNeeded = $false
$toInstall    = @($results | Where-Object { $_.Check -eq 'Needed' -and $_.Download -in 'Downloaded', 'Already present' })

if ($DownloadOnly) {
    Write-Log ''
    Write-Log '-DownloadOnly specified: skipping install, verification, and cleanup.'
}
elseif (-not $isAdmin) {
    Write-Log ''
    Write-Log 'Not elevated: skipping install, verification, and cleanup.' -Level WARN
}
elseif (-not $toInstall) {
    Write-Log ''
    Write-Log 'Nothing to install.'
}
else {
    # Step 4: final check by patch code, then install (required first, then optional)
    Write-Log ''
    Write-Log '=== Installing patches ==='

    foreach ($r in $toInstall) {
        Write-Log "$($r.Latest)"
        try {
            $info        = Get-MspInfo -Path $r.Path
            $r.PatchCode = $info.PatchCode
            Write-Log "  Patch code: $($info.PatchCode)"

            # Confirm the MSP is the patch we expect for this prefix
            $expectedName = Get-ExpectedPatchName -Prefix $r.Prefix -PatchName $r.Latest
            if ($info.DisplayName -and $expectedName) {
                if ($info.DisplayName -eq $expectedName) {
                    Write-Verbose "  Registers in Windows as '$($info.DisplayName)' (matches mapping)."
                }
                else {
                    Write-Log "  Registers as '$($info.DisplayName)' but the mapping expects '$expectedName' - check `$PatchDisplayNames." -Level WARN
                }
            }
            elseif ($info.DisplayName) {
                Write-Log "  Registers in Windows as: $($info.DisplayName)"
            }

            # Remember the patch code so future runs can skip the download
            $patchCache[(Get-PatchCacheKey $r.Latest)] = [pscustomobject]@{
                PatchCode      = $info.PatchCode
                TargetProducts = @($info.TargetProducts)
                DisplayName    = $info.DisplayName
            }
            $cacheChanged = $true

            # Only apply if at least one target product is installed
            $r.TargetProducts = @(Get-InstalledTargetProduct -ProductCodes $info.TargetProducts)
            if (-not $r.TargetProducts) {
                Write-Log '  None of the products this patch targets are installed - skipping.' -Level WARN
                $r.Install = 'Not applicable'
                continue
            }
            Write-Log "  Target product(s) installed: $($r.TargetProducts -join ', ')"

            # Backstop: catches patches whose registered name didn't match by name
            $states = @(Get-MspInstallState -PatchCode $r.PatchCode -InstalledProducts $r.TargetProducts)
            if (Test-MspApplied $states) {
                Write-Log "  Already applied ($(($states.State | Sort-Object -Unique) -join ', ')) - skipping." -Level SKIP
                $r.Install  = 'Already installed'
                $r.Verified = $true
                continue
            }

            $r.ExitCode = Install-ImageRightPatch -MspPath $r.Path -LogDirectory $LogPath
            $r.Install  = Get-InstallOutcome $r.ExitCode
            if ($r.ExitCode -in 3010, 1641) { $rebootNeeded = $true }

            $level = if ($r.Install -like 'Installed*') { 'SUCCESS' } elseif ($r.Install -eq 'Not applicable') { 'WARN' } else { 'ERROR' }
            Write-Log "  Result: $($r.Install) (exit code $($r.ExitCode))" -Level $level
        }
        catch {
            Write-Log "  Install error: $($_.Exception.Message)" -Level ERROR
            $r.Install = 'Failed (error)'
        }
    }

    # Step 5: verify against Windows Installer's patch registration
    Write-Log ''
    Write-Log '=== Verifying installation ==='

    foreach ($r in $toInstall) {
        if ($r.Install -notlike 'Installed*') { continue }

        $states     = @(Get-MspInstallState -PatchCode $r.PatchCode -InstalledProducts $r.TargetProducts)
        $r.Verified = Test-MspApplied $states

        foreach ($s in $states) {
            $level = if ($s.State -in 'Applied', 'Superseded') { 'SUCCESS' } else { 'ERROR' }
            Write-Log "$($r.Latest) on $($s.ProductCode): $($s.State)" -Level $level
        }
    }

    # Step 6: clean up
    Write-Log ''
    if ($KeepDownloads) {
        Write-Log '-KeepDownloads specified: leaving downloaded files in place.'
    }
    else {
        Write-Log '=== Cleaning up ==='
        Write-Log "Waiting $CleanupDelaySeconds seconds for file locks to clear..."
        Start-Sleep -Seconds $CleanupDelaySeconds
        Remove-PatchFile -Results $toInstall -DownloadFolder $Destination `
            -Retries $CleanupRetries -DelaySeconds $CleanupDelaySeconds
    }
}

# --- Save patch-code cache ----------------------------------------------------
if ($cacheChanged) { Save-PatchCache -Cache $patchCache -Path $PatchCachePath }

# --- Summary ------------------------------------------------------------------
Write-Log ''
Write-Log '=== Summary ==='
$summary = $results | Format-Table Category, Prefix, Latest, Check, Download, Install, Verified, Cleanup -AutoSize | Out-String -Width 250
Write-Host $summary
Add-Content -Path $script:LogFile -Value $summary

$missingRequired = @($results | Where-Object { $_.Check -eq 'Base app missing' })
if ($missingRequired) {
    Write-Log "Required base app(s) missing on this machine: $(($missingRequired.BaseApp) -join ', ')" -Level WARN
}

$failed = @($results | Where-Object {
    $_.Download -eq 'Failed' -or $_.Install -like 'Failed*' -or $_.Verified -eq $false
})

if ($rebootNeeded) { Write-Log 'A reboot is required to finish installing one or more patches.' -Level WARN }

if ($failed.Count) {
    Write-Log "$($failed.Count) item(s) failed. See $script:LogFile" -Level ERROR
    exit 1
}
elseif ($rebootNeeded) {
    exit 3010
}
Write-Log 'Run completed successfully.' -Level SUCCESS
exit 0
