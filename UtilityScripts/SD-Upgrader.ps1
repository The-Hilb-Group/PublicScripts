#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs or upgrades the SmartDeploy Client (cloud-only) from Hilb blob storage.

.DESCRIPTION
    1. Downloads the SmartDeploy Client MSI using BITS, falling back to
       Invoke-WebRequest (with retries) only if BITS is unavailable or fails.
       Validates the download against a known SHA256 hash.
    2. Compares the MSI ProductVersion with the installed client version and exits
       if the installed version is already current.
    3. If an older version is installed, stops the service and uninstalls it via
       msiexec /x. Registry and file remnants are removed only if that fails.
    4. Installs the new version, verifies it, and retries once if msiexec failed.

.NOTES
    Version : 1.4
    Runs on : Windows PowerShell 5.1 and PowerShell 7+ (Windows only)

    Logs    : C:\Temp\SDClient-Upgrader.log   script log (rotated at 5 MB)
              C:\Temp\SDClient-install.log    msiexec verbose install log
              C:\Temp\SDClient-uninstall.log  msiexec verbose uninstall log
    Download: C:\Temp\SDClientSetup-cloudonly.msi (deleted when the script finishes)

    Exit codes:
      0     Success (installed, upgraded, or already current)
      3010  Success, reboot required (only when $ReturnRebootCode = $true)
      1     Unexpected script error
      2     Download failure or SHA256 hash mismatch
      3     msiexec reported success but the installed version could not be verified
      1618  Another Windows Installer operation did not finish in time
      Other The msiexec exit code from the final install attempt
#>

[CmdletBinding()]
param()

#region ---------- Platform and 64-bit checks ----------
# PowerShell 7 runs cross-platform; this script manages a Windows MSI only.
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    Write-Error 'This script only supports Windows.'
    exit 1
}

# A 32-bit host (common with RMM agents) silently redirects HKLM\SOFTWARE and
# System32, which would make detection and cleanup look in the wrong places.
# Relaunch in the 64-bit build of the same edition when possible, otherwise
# fall back to 64-bit Windows PowerShell 5.1 (which is always present).
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $relaunchHost = $null
    if ($PSVersionTable.PSEdition -eq 'Core' -and $env:ProgramW6432) {
        $pwsh64 = Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe'
        if (Test-Path $pwsh64) { $relaunchHost = $pwsh64 }
    }
    if (-not $relaunchHost) {
        $winPs64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $winPs64) { $relaunchHost = $winPs64 }
    }
    if ($PSCommandPath -and $relaunchHost) {
        & $relaunchHost -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
    Write-Warning 'Running in 32-bit PowerShell and unable to relaunch as 64-bit. Results may be unreliable.'
}
#endregion

#region ---------- Configuration ----------
$DownloadUrl   = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/SDClientSetup-cloudonly.msi'
$WorkingDir    = 'C:\Temp'      # installer download location
$LogDir        = $WorkingDir    # script and msiexec log location
$InstallerPath = Join-Path $WorkingDir 'SDClientSetup-cloudonly.msi'
$ClientExePath = 'C:\Program Files\SmartDeploy\ClientService\SDClientService.exe'
$ServiceName   = 'SDClientService'

# Uninstall entries whose DisplayName matches this pattern are removed during an upgrade.
# TODO: Narrow this to the client's exact DisplayName so a SmartDeploy Console install
#       on a technician machine is never touched.
$UninstallNamePattern = '*SmartDeploy*'

# Set to $false if the MSI performs a major upgrade on its own (test this first).
$UninstallBeforeUpgrade = $true

# SHA256 of the approved MSI. The script refuses to install anything that does not match.
# IMPORTANT: Update this whenever the MSI in blob storage is replaced; otherwise every
#            run will stop with exit code 2. Get the value from a known-good copy with:
#   (Get-FileHash .\SDClientSetup-cloudonly.msi -Algorithm SHA256).Hash
$ExpectedSha256 = 'B1D3732E914C1566899C068D841A80CD7A9AC5BCA1C2BB39814480A26CD7C2E0'

# BITS is the primary download method. Invoke-WebRequest is used only when BITS
# is unavailable (service disabled, module missing) or the BITS job fails/times out.
$UseBits           = $true
$BitsTimeoutMin    = 15
$BitsJobName       = 'Hilb-SDClient-Download'

$DownloadAttempts  = 3            # Invoke-WebRequest fallback attempts
$InstallAttempts   = 2
$MsiBusyTimeoutMin = 10
$ReturnRebootCode  = $false   # $true = exit 3010 when msiexec reports a pending reboot

$LogFile      = Join-Path $LogDir 'SDClient-Upgrader.log'
$InstallLog   = Join-Path $LogDir 'SDClient-install.log'
$UninstallLog = Join-Path $LogDir 'SDClient-uninstall.log'

$MsiSuccessCodes = @(0, 1641, 3010)
$MsiRebootCodes  = @(1641, 3010)
$MsiNotInstalled = 1605

$ErrorActionPreference  = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # Invoke-WebRequest is very slow with progress on
$script:RebootRequired  = $false
#endregion

#region ---------- Logging ----------
function Initialize-WorkingDir {
    foreach ($dir in @($WorkingDir, $LogDir) | Select-Object -Unique) {
        if (-not (Test-Path -Path $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
        Move-Item -Path $LogFile -Destination "$LogFile.old" -Force
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string] $Level = 'INFO'
    )
    $line  = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}
#endregion

#region ---------- Version helpers ----------
function ConvertTo-FullVersion {
    # Pads missing components with 0 so 3-part and 4-part versions compare correctly.
    param([Parameter(Mandatory)][Version] $Version)
    New-Object System.Version -ArgumentList $Version.Major,
        ([Math]::Max($Version.Minor, 0)),
        ([Math]::Max($Version.Build, 0)),
        ([Math]::Max($Version.Revision, 0))
}

# Reads MSI properties through msi.dll directly. COM late binding against
# WindowsInstaller.Installer behaves differently on .NET (PowerShell 7) than on
# .NET Framework (5.1); P/Invoke behaves the same on both and closes its handles
# deterministically, so no COM release or garbage collection is needed.
function Initialize-MsiReader {
    # Compiled on first use so any failure is caught and logged by the main try/catch.
    if ('HilbSdMsiReader' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HilbSdMsiReader
{
    // MSIHANDLE is a 32-bit unsigned value on both x86 and x64.
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiOpenDatabase(string szDatabasePath, IntPtr szPersist, out uint phDatabase);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiDatabaseOpenView(uint hDatabase, string szQuery, out uint phView);

    [DllImport("msi.dll")]
    private static extern uint MsiViewExecute(uint hView, uint hRecord);

    [DllImport("msi.dll")]
    private static extern uint MsiViewFetch(uint hView, out uint phRecord);

    [DllImport("msi.dll")]
    private static extern uint MsiViewClose(uint hView);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiRecordGetString(uint hRecord, uint iField, StringBuilder szValueBuf, ref uint pcchValueBuf);

    [DllImport("msi.dll")]
    private static extern uint MsiCloseHandle(uint hAny);

    private const uint ERROR_SUCCESS       = 0;
    private const uint ERROR_MORE_DATA     = 234;
    private const uint ERROR_NO_MORE_ITEMS = 259;

    private static void Check(uint result, string operation)
    {
        if (result != ERROR_SUCCESS)
            throw new InvalidOperationException(operation + " failed with Windows Installer error " + result + ".");
    }

    // Returns the value of an MSI Property table entry, or null if it is not present.
    public static string GetProperty(string msiPath, string propertyName)
    {
        uint db = 0, view = 0, record = 0;
        try
        {
            // IntPtr.Zero == MSIDBOPEN_READONLY
            Check(MsiOpenDatabase(msiPath, IntPtr.Zero, out db), "MsiOpenDatabase");

            string query = "SELECT `Value` FROM `Property` WHERE `Property` = '" + propertyName.Replace("'", "''") + "'";
            Check(MsiDatabaseOpenView(db, query, out view), "MsiDatabaseOpenView");
            Check(MsiViewExecute(view, 0), "MsiViewExecute");

            uint fetch = MsiViewFetch(view, out record);
            if (fetch == ERROR_NO_MORE_ITEMS) return null;
            Check(fetch, "MsiViewFetch");

            uint size = 256;
            StringBuilder buffer = new StringBuilder((int)size);
            uint result = MsiRecordGetString(record, 1, buffer, ref size);
            if (result == ERROR_MORE_DATA)
            {
                size++;
                buffer = new StringBuilder((int)size);
                result = MsiRecordGetString(record, 1, buffer, ref size);
            }
            Check(result, "MsiRecordGetString");
            return buffer.ToString();
        }
        finally
        {
            if (record != 0) MsiCloseHandle(record);
            if (view != 0) { MsiViewClose(view); MsiCloseHandle(view); }
            if (db != 0) MsiCloseHandle(db);
        }
    }
}
'@
}

function Get-MsiProductVersion {
    param([Parameter(Mandatory)][string] $MsiPath)

    Initialize-MsiReader
    $value = [HilbSdMsiReader]::GetProperty($MsiPath, 'ProductVersion')
    if (-not $value) { throw 'ProductVersion property not found in the MSI.' }
    return ConvertTo-FullVersion -Version ([Version]$value)
}

function Get-InstalledClientVersion {
    # Returns $null when the client is not installed.
    if (-not (Test-Path -LiteralPath $ClientExePath)) { return $null }

    # The numeric File*Part fields avoid parsing the free-text FileVersion string.
    $vi = (Get-Item -LiteralPath $ClientExePath).VersionInfo
    New-Object System.Version -ArgumentList $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
}
#endregion

#region ---------- Download and validation ----------
function Test-BitsAvailable {
    if (-not $UseBits) {
        Write-Log 'BITS is disabled by configuration.'
        return $false
    }

    $svc = Get-Service -Name 'BITS' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log 'BITS service not found.' WARN
        return $false
    }
    if ("$($svc.StartType)" -eq 'Disabled') {
        Write-Log 'BITS service is disabled.' WARN
        return $false
    }

    $module = Get-Module -ListAvailable -Name 'BitsTransfer' | Select-Object -First 1
    if (-not $module) {
        Write-Log 'BitsTransfer PowerShell module not found.' WARN
        return $false
    }

    # BitsTransfer is natively compatible with PowerShell 7 only on Windows 10/Server 20H1
    # and later. On older builds PowerShell 7 would load it through the Windows PowerShell
    # compatibility layer, which returns disconnected job objects that cannot be polled or
    # completed reliably, so treat BITS as unavailable there.
    if ($PSVersionTable.PSEdition -eq 'Core' -and $module.CompatiblePSEditions -notcontains 'Core') {
        Write-Log 'BitsTransfer module is not natively compatible with PowerShell 7 on this OS build.' WARN
        return $false
    }

    try {
        Import-Module -Name 'BitsTransfer' -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "Unable to load BitsTransfer module: $($_.Exception.Message)" WARN
        return $false
    }
}

function Remove-BitsJobSafe {
    param($Job)
    if (-not $Job) { return }
    try { Remove-BitsTransfer -BitsJob $Job -ErrorAction Stop } catch { }
}

function Save-InstallerWithBits {
    $jobId = $null
    try {
        # Clear out any job left behind by an earlier, interrupted run.
        Get-BitsTransfer -Name $BitsJobName -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-BitsJobSafe -Job $_ }

        if (Test-Path -LiteralPath $InstallerPath) { Remove-Item -LiteralPath $InstallerPath -Force }

        Write-Log "Downloading installer with BITS (timeout $BitsTimeoutMin minutes)..."
        # Asynchronous so the script controls the timeout; a synchronous BITS job can
        # keep retrying transient errors far longer than an RMM task should run.
        $job = Start-BitsTransfer -Source $DownloadUrl -Destination $InstallerPath `
            -DisplayName $BitsJobName -Priority Foreground -Asynchronous -ErrorAction Stop
        $jobId     = $job.JobId
        $deadline  = (Get-Date).AddMinutes($BitsTimeoutMin)
        $lastState = ''
        $lastProgressLog = Get-Date

        while ($true) {
            # Re-query each loop rather than relying on the original object refreshing.
            $job   = Get-BitsTransfer -JobId $jobId -ErrorAction Stop
            $state = "$($job.JobState)"

            if ($state -ne $lastState) {
                $detail = if ($state -eq 'TransientError') { ": $($job.ErrorDescription)".Trim() } else { '' }
                Write-Log "BITS job state: $state$detail"
                $lastState = $state
            }

            if ($state -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                $actualSize = (Get-Item -LiteralPath $InstallerPath).Length
                Write-Log ('BITS download complete: {0:N2} MB.' -f ($actualSize / 1MB)) OK
                return $true
            }

            if ($state -eq 'Error' -or $state -eq 'Cancelled') {
                $reason = "$($job.ErrorDescription)".Trim()
                Write-Log "BITS job failed ($($job.ErrorContextDescription)): $reason" WARN
                Remove-BitsJobSafe -Job $job
                return $false
            }

            if ($state -eq 'Suspended') {
                Resume-BitsTransfer -BitsJob $job -Asynchronous -ErrorAction Stop | Out-Null
            }

            if ((Get-Date) -ge $deadline) {
                Write-Log "BITS job did not finish within $BitsTimeoutMin minutes (last state: $state)." WARN
                Remove-BitsJobSafe -Job $job
                return $false
            }

            if (((Get-Date) - $lastProgressLog).TotalSeconds -ge 30 -and $state -eq 'Transferring' -and
                $job.BytesTotal -gt 0 -and $job.BytesTotal -lt [uint64]::MaxValue) {
                Write-Log ('BITS progress: {0:N1} of {1:N1} MB' -f ($job.BytesTransferred / 1MB), ($job.BytesTotal / 1MB))
                $lastProgressLog = Get-Date
            }

            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-Log "BITS download error: $($_.Exception.Message)" WARN
        if ($jobId) {
            Remove-BitsJobSafe -Job (Get-BitsTransfer -JobId $jobId -ErrorAction SilentlyContinue)
        }
        return $false
    }
}

function Save-InstallerWithWebRequest {
    # Windows PowerShell 5.1 may not enable TLS 1.2 by default, which Azure Storage requires.
    # PowerShell 7 uses HttpClient with OS-negotiated TLS, so no change is needed there.
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    for ($attempt = 1; $attempt -le $DownloadAttempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $InstallerPath) { Remove-Item -LiteralPath $InstallerPath -Force }

            Write-Log "Downloading installer with Invoke-WebRequest (attempt $attempt of $DownloadAttempts)..."
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -UseBasicParsing -ErrorAction Stop

            $actualSize = (Get-Item -LiteralPath $InstallerPath).Length
            Write-Log ('Download complete: {0:N2} MB.' -f ($actualSize / 1MB)) OK
            return $true
        }
        catch {
            Write-Log "Download attempt $attempt failed: $($_.Exception.Message)" WARN
        }

        if ($attempt -lt $DownloadAttempts) { Start-Sleep -Seconds (15 * $attempt) }
    }

    Write-Log "Download failed after $DownloadAttempts attempts." ERROR
    return $false
}

function Save-Installer {
    # BITS first; Invoke-WebRequest only if BITS is unavailable or fails.
    if (Test-BitsAvailable) {
        if (Save-InstallerWithBits) { return $true }
        Write-Log 'BITS download failed; falling back to Invoke-WebRequest.' WARN
    }
    else {
        Write-Log 'BITS is unavailable; using Invoke-WebRequest.' WARN
    }
    return Save-InstallerWithWebRequest
}

function Test-InstallerHash {
    if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        Write-Log "Configured `$ExpectedSha256 is not a valid SHA256 value: '$ExpectedSha256'." ERROR
        return $false
    }

    $actual = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash
    if ($actual -eq $ExpectedSha256) {   # -eq is case-insensitive
        Write-Log "SHA256 hash verified: $actual" OK
        return $true
    }

    Write-Log 'SHA256 hash mismatch. The installer will not be used.' ERROR
    Write-Log "  Expected: $($ExpectedSha256.ToUpperInvariant())" ERROR
    Write-Log "  Actual:   $actual" ERROR
    Write-Log '  If the MSI in blob storage was intentionally updated, update $ExpectedSha256.' ERROR
    return $false
}
#endregion

#region ---------- Windows Installer helpers ----------
function Test-MsiBusy {
    # Windows Installer holds this mutex while an install/uninstall is running.
    # Checking for msiexec processes is unreliable because the service host lingers.
    $mutex = $null
    try {
        if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mutex)) {
            $mutex.Dispose()
            return $true
        }
        return $false
    }
    catch {
        # The mutex exists but we cannot open it, so an install is running.
        # (.NET exceptions arrive wrapped in a MethodInvocationException.)
        if ($_.Exception -is [UnauthorizedAccessException] -or
            $_.Exception.InnerException -is [UnauthorizedAccessException]) {
            return $true
        }
        throw
    }
}

function Wait-MsiAvailable {
    $deadline = (Get-Date).AddMinutes($MsiBusyTimeoutMin)
    while (Test-MsiBusy) {
        if ((Get-Date) -ge $deadline) {
            Write-Log "Windows Installer is still busy after $MsiBusyTimeoutMin minutes." ERROR
            return $false
        }
        Write-Log 'Another Windows Installer operation is in progress; waiting 15 seconds...'
        Start-Sleep -Seconds 15
    }
    return $true
}

function Invoke-Msiexec {
    param([Parameter(Mandatory)][string] $Arguments)

    if (-not (Wait-MsiAvailable)) { return 1618 }

    Write-Log "msiexec.exe $Arguments"
    $proc = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $Arguments -Wait -PassThru
    if ($proc.ExitCode -in $MsiRebootCodes) { $script:RebootRequired = $true }
    return $proc.ExitCode
}
#endregion

#region ---------- Uninstall and cleanup ----------
function Stop-ClientService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Log "Stopping service $ServiceName..."
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        catch {
            Write-Log "Could not stop $($ServiceName): $($_.Exception.Message)" WARN
        }
    }
}

function Get-SmartDeployProducts {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem -Path $root -ErrorAction SilentlyContinue) {
            $name = $key.GetValue('DisplayName')
            if (-not $name -or $name -notlike $UninstallNamePattern) { continue }

            $code = $null
            if ($key.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                $code = $key.PSChildName
            }
            elseif ("$($key.GetValue('UninstallString'))" -match '\{[0-9A-Fa-f-]{36}\}') {
                $code = $Matches[0]
            }

            [pscustomobject]@{
                DisplayName    = $name
                DisplayVersion = $key.GetValue('DisplayVersion')
                ProductCode    = $code
            }
        }
    }
}

function Uninstall-SmartDeploy {
    # Returns $true only if every matching product was uninstalled successfully.
    $products = @(Get-SmartDeployProducts)
    if ($products.Count -eq 0) {
        Write-Log 'No SmartDeploy uninstall entries found in the registry.' WARN
        return $false
    }

    $allSucceeded = $true
    foreach ($p in $products) {
        if (-not $p.ProductCode) {
            Write-Log "Skipping '$($p.DisplayName)': no MSI product code found." WARN
            $allSucceeded = $false
            continue
        }

        Write-Log "Uninstalling '$($p.DisplayName)' $($p.DisplayVersion) $($p.ProductCode)..."
        # /x (not /i) guarantees a removal rather than a maintenance/repair run.
        $code = Invoke-Msiexec -Arguments "/x $($p.ProductCode) /qn /norestart /l*v+ `"$UninstallLog`""

        if ($code -in $MsiSuccessCodes -or $code -eq $MsiNotInstalled) {
            Write-Log "Uninstalled '$($p.DisplayName)' (exit code $code)." OK
        }
        else {
            Write-Log "Uninstall of '$($p.DisplayName)' failed with exit code $code." WARN
            $allSucceeded = $false
        }
    }
    return $allSucceeded
}

function Remove-RegistryKeyTree {
    # Uses the .NET API so key names containing '/' are handled correctly
    # (the PowerShell registry provider treats '/' as a path separator).
    param([Parameter(Mandatory)][string] $SubKey)   # path relative to HKLM

    $split      = $SubKey.LastIndexOf('\')
    $parentPath = $SubKey.Substring(0, $split)
    $leaf       = $SubKey.Substring($split + 1)
    $parent     = $null
    try {
        $parent = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parentPath, $true)
        if ($parent -and ($parent.GetSubKeyNames() -contains $leaf)) {
            $parent.DeleteSubKeyTree($leaf)
            Write-Log "Removed registry key HKLM\$SubKey"
        }
    }
    catch {
        Write-Log "Failed to remove HKLM\$($SubKey): $($_.Exception.Message)" WARN
    }
    finally {
        if ($parent) { $parent.Close() }
    }
}

function Remove-RegistryValue {
    param(
        [Parameter(Mandatory)][string] $SubKey,   # path relative to HKLM
        [Parameter(Mandatory)][string] $Name
    )
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $true)
        if ($key -and ($key.GetValueNames() -contains $Name)) {
            $key.DeleteValue($Name, $false)
            Write-Log "Removed registry value HKLM\$SubKey\$Name"
        }
    }
    catch {
        Write-Log "Failed to remove HKLM\$SubKey\$($Name): $($_.Exception.Message)" WARN
    }
    finally {
        if ($key) { $key.Close() }
    }
}

function Remove-SmartDeployRemnants {
    # Last-resort cleanup. Only called when a normal uninstall or install fails.
    Write-Log 'Removing SmartDeploy registry and file remnants...' WARN

    $keys = @(
        # Windows Installer per-machine product registrations (HKCR\Installer\Products)
        'SOFTWARE\Classes\Installer\Products\0A4F77B87FDAA124F9BADE052B7F4A85'
        'SOFTWARE\Classes\Installer\Products\16EDC03CA8666B045AD49370A1CB101C'
        'SOFTWARE\Classes\Installer\Products\F588D9A7B92AFE44B9B6D41CD21F61BC'
        'SOFTWARE\Classes\Installer\Products\3AE76BCF86EC85440B8F34C385BF2E35'
        'SOFTWARE\Classes\Installer\Products\772106ECC43E9A24BB17897E19538208'
        'SOFTWARE\Classes\Installer\Products\A325E1EDF41A10140A46F166D3BC7EBC'
        'SOFTWARE\Classes\Installer\Products\15389F7137F1E0F4CB120CE8C319330C'
        'SOFTWARE\Classes\Installer\Products\0ABA56F08921639418A88330E257C2B7'
        'SOFTWARE\Classes\Installer\Products\96029F5716AA7B74F83EBF3207B0DEF6'

        # COM AppIDs (HKCR\AppID)
        'SOFTWARE\Classes\AppID\{68588B7E-9DA7-4D29-9292-1ADAE1CA1192}'
        'SOFTWARE\Classes\AppID\SmartDeploy.EXE'

        # Uninstall entries
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{0F65ABA0-1298-4936-818A-38032E752C7B}'
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{75F92069-AA61-47B7-8FE3-FB23700BED6F}'

        # Group Policy software installation record.
        # NOTE: Removing this can cause GPO software installation to redeploy. Confirm intended.
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Appmgmt\{09427150-57f9-4d1c-829d-96db1299e5d3}'

        # Services and event log sources
        'SYSTEM\CurrentControlSet\Services\EventLog\Application\SmartDeploy'
        'SYSTEM\CurrentControlSet\Services\EventLog\Application\SmartDeploy Client Service'
        'SYSTEM\CurrentControlSet\Services\EventLog\Application\SmartDeploy Console/Client Service'
        'SYSTEM\CurrentControlSet\Services\SmartDeploy'
        'SYSTEM\Setup\FirstBoot\Services\SmartDeploy'
    )

    # v4.1 targeted these as keys, but InstallSource is a value. Removed as values here.
    # TODO: If the intent was to remove the whole uninstall entry, move the parent
    #       keys into the $keys list above instead.
    $values = @(
        @{ Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{7A9D885F-A29B-44EF-9B6B-4DC12DF116CB}'; Name = 'InstallSource' }
        @{ Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{CE601277-E34C-42A9-BB71-98E791352880}'; Name = 'InstallSource' }
        @{ Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{DE1E523A-A14F-4101-A064-1F663DCBE7CB}'; Name = 'InstallSource' }
        @{ Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{17F98351-1F73-4F0E-BC21-C08E3C9133C0}'; Name = 'InstallSource' }
    )

    $paths = @(
        (Join-Path $env:WINDIR 'System32\SmartDeploy.dll')
        (Join-Path $env:WINDIR 'System32\SmartDeploy.exe')
        (Join-Path $env:WINDIR 'SysWOW64\SmartDeploy.dll')
        (Join-Path $env:WINDIR 'SysWOW64\SmartDeploy.exe')
        (Join-Path $env:WINDIR 'SysWOW64\SmartDeploy')
    )

    foreach ($k in $keys)   { Remove-RegistryKeyTree -SubKey $k }
    foreach ($v in $values) { Remove-RegistryValue -SubKey $v.Key -Name $v.Name }

    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            try {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
                Write-Log "Removed $p"
            }
            catch {
                Write-Log "Failed to remove $($p): $($_.Exception.Message)" WARN
            }
        }
    }
}
#endregion

#region ---------- Main workflow ----------
function Invoke-SmartDeployUpgrade {
    Write-Log '===== SmartDeploy Client upgrader v4.9 starting ====='
    Write-Log "Computer: $env:COMPUTERNAME | Account: $([Environment]::UserName) | 64-bit process: $([Environment]::Is64BitProcess)"
    Write-Log "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

    # 1. Download and validate
    if (-not (Save-Installer))      { return 2 }
    if (-not (Test-InstallerHash))  { return 2 }

    # 2. Compare versions
    $targetVersion    = Get-MsiProductVersion -MsiPath $InstallerPath
    $installedVersion = Get-InstalledClientVersion
    $installedText    = if ($installedVersion) { "$installedVersion" } else { 'not installed' }
    Write-Log "Installer version: $targetVersion | Installed version: $installedText"

    if ($installedVersion -and $installedVersion -ge $targetVersion) {
        Write-Log 'Installed version is current. No action needed.' OK
        return 0
    }

    # 3. Remove the old version
    if ($installedVersion -and $UninstallBeforeUpgrade) {
        Stop-ClientService
        if (-not (Uninstall-SmartDeploy)) {
            Write-Log 'Uninstall did not complete cleanly; falling back to remnant cleanup.' WARN
            Remove-SmartDeployRemnants
        }
    }

    # 4. Install and verify
    $installArgs = "/i `"$InstallerPath`" /qn /norestart /l*v+ `"$InstallLog`""
    $exitCode    = 1

    for ($attempt = 1; $attempt -le $InstallAttempts; $attempt++) {
        Write-Log "Installing SmartDeploy Client $targetVersion (attempt $attempt of $InstallAttempts)..."
        $exitCode = Invoke-Msiexec -Arguments $installArgs
        if ($exitCode -eq 1618) { return 1618 }

        $nowInstalled = Get-InstalledClientVersion
        $nowText      = if ($nowInstalled) { "$nowInstalled" } else { 'not installed' }

        if ($exitCode -in $MsiSuccessCodes) {
            if ($nowInstalled -and $nowInstalled -ge $targetVersion) {
                Write-Log "SmartDeploy Client $nowInstalled installed successfully (exit code $exitCode)." OK
                if ($script:RebootRequired) {
                    Write-Log 'A reboot is required to complete the installation.' WARN
                    if ($ReturnRebootCode) { return 3010 }
                }
                return 0
            }

            # msiexec succeeded but detection disagrees. Retrying will not help;
            # most likely the EXE file version does not match the MSI ProductVersion.
            Write-Log "msiexec reported success, but detected version is $nowText (expected $targetVersion or later). Confirm $ClientExePath reports the same version as the MSI ProductVersion." ERROR
            return 3
        }

        Write-Log "Install attempt $attempt failed with exit code $exitCode (detected version: $nowText). See $InstallLog" WARN
        if ($attempt -lt $InstallAttempts) {
            Stop-ClientService
            Remove-SmartDeployRemnants
            Start-Sleep -Seconds 10
        }
    }

    Write-Log "SmartDeploy Client installation failed with exit code $exitCode. Manual intervention required." ERROR
    return $exitCode
}
#endregion

#region ---------- Entry point ----------
$ScriptExitCode = 1
try {
    Initialize-WorkingDir
    $ScriptExitCode = [int](Invoke-SmartDeployUpgrade)
}
catch {
    Write-Log "Unexpected error: $($_.Exception.Message)" ERROR
    Write-Log "Location: $($_.InvocationInfo.PositionMessage)" ERROR
    $ScriptExitCode = 1
}
finally {
    if (Test-Path -LiteralPath $InstallerPath) {
        try {
            Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction Stop
            Write-Log 'Removed downloaded installer.'
        }
        catch {
            Write-Log "Could not remove installer $($InstallerPath): $($_.Exception.Message)" WARN
        }
    }
    Write-Log "===== Finished with exit code $ScriptExitCode ====="
}

exit $ScriptExitCode
#endregion
