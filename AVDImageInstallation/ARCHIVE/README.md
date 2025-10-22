# AVD Image Installation — BaseImageInstall.ps1

This README documents the `BaseImageInstall.ps1` script in this folder. The script contains helper functions used to build and configure Windows images for AVD (Azure Virtual Desktop) or similar automated image creation workflows. It is intended to be run from an elevated PowerShell session and supports both interactive and unattended usage.

## Contents
- `BaseImageInstall.ps1` — PowerShell functions to download and install common components used in the AVD base image build process.

## Synopsis
The script provides modular functions to install or remove the following components:
- .NET Framework 4.8
- Microsoft Edge WebView2 Runtime (x86 installer)
- Chocolatey package manager and Chocolatey package installation helper
- Adobe Acrobat (web installer + MST transform)
- AMS360 (MSI installer)
- Quick Assist removal helper (Remove-QuickAssist)

Each function is self-contained and can be executed independently or as part of a larger provisioning pipeline.

## Usage
Open an elevated PowerShell (Run as Administrator) session on the machine where you are preparing the image.

Dot-source the script to import its functions into the current session:

```powershell
. "C:\Path\To\AVDImageInstallation\BaseImageInstall.ps1"
```

Then call any function directly, for example:

```powershell
Install-Net48
Install-Web2View
Install-Chocolatey
Install-ChocoPackages -Packages @("git","7zip")
Install-AdobeAcrobat
Install-AMS360
Remove-QuickAssist
```

For unattended runs inside a larger automation pipeline, invoke the specific functions you need from a wrapper script or use PowerShell's `-Command` or `-File` parameters from the command line. Ensure the process is elevated.

Example unattended invocation (from an elevated PowerShell process):

```powershell
# Dot-source and run multiple installs in a single script
. "C:\Path\To\AVDImageInstallation\BaseImageInstall.ps1"
Install-Net48
Install-Web2View
Install-Chocolatey
Install-ChocoPackages -Packages @('git','7zip')
Install-AdobeAcrobat
Install-AMS360
Remove-QuickAssist
```

## Function reference
Below is a brief description of each exported function (names as defined in the script).

- Get-TempFilePath
  - Inputs: `-FileName` (string)
  - Output: full path string in the system temporary folder
  - Notes: does not create the file; only composes a valid temp path.

- Invoke-DownloadAndStartProcess
  - Inputs: `-DownloadURL` (string), `-FileName` (string), `-Arguments` (string)
  - Behavior: downloads the file to a temp path and starts it with the supplied arguments; waits for the process to exit.
  - Error modes: throws on download or process start errors unless wrapped by caller.

- Install-Net48
  - Behavior: checks the registry for an existing .NET 4.x installation and skips installation if found; otherwise downloads the redistributable and runs it silently with `/q /norestart`.
  - Default source: Microsoft-hosted or internal blob URL configured in the script.

- Install-Web2View
  - Behavior: checks the local MSI/Product registry for WebView2 and runs the x86 installer silently if not present.
  - Default source: internal blob URL configured in the script.

- Install-Chocolatey
  - Behavior: installs Chocolatey by invoking the official install script using a temporary bypass execution policy.
  - Notes: must be run as admin and requires internet access.

- Install-ChocoPackages
  - Inputs: `-Packages` (string[])
  - Behavior: runs `choco install` for each package using `-y -Force --ignore-checksums`.
  - Notes: depends on Chocolatey being installed and network access to package sources.

- Install-AdobeAcrobat
  - Behavior: downloads the Acrobat web installer ZIP, extracts it to the temp dir, downloads an MST transform to the product `Transforms` folder, and runs `setup.exe` with corporate silent switches.
  - Notes: the MST file path and setup arguments are configured in the script. Verify the transform URL and `AcroPro.mst` presence if installation fails.

- Install-AMS360
  - Behavior: downloads an MSI (URL configured in the script) and runs it with `/qn`.
  - Notes: cleans up a couple of known public desktop shortcuts created by that installer.

- Remove-QuickAssist
  - Behavior: queries Windows capabilities for QuickAssist and removes it if installed.
  - Notes: uses `Get-WindowsCapability -Online` and `Remove-WindowsCapability -Online` which require elevated privileges and may take time to complete. The function captures and returns the error message string when removal fails.

## Example: install sequence for a base image
1. Boot a provisioning VM, log in with an admin account.
2. Open PowerShell as Administrator.
3. Dot-source the script and run the desired sequence of functions:

```powershell
. "C:\AVDImageInstallation\BaseImageInstall.ps1"
Install-Net48
Install-Web2View
Install-Chocolatey
Install-ChocoPackages -Packages @('git','7zip','notepadplusplus')
Install-AdobeAcrobat
Install-AMS360
Remove-QuickAssist
```

Wrap these calls in a larger image build automation script (such as a Packer or Azure Image Builder step) to produce repeatable images.

## Prerequisites and permissions
- Must run with Administrator privileges for most functions.
- Network access to the configured download URLs (external or internal blob storage).
- Sufficient free disk space in `%TEMP%` and system drive for installers and extracted content.
- Execution policy for installing Chocolatey: the script temporarily sets Bypass for the current process.

## Edge cases and troubleshooting
- Failing downloads: verify network connectivity and reachable URLs. Retry or host installers in an internal storage account with reliable access.
- Registry checks: `Install-Net48` checks the v4 Full key; machines with nonstandard registry layouts may need a manual check.
- MSI/Product detection: `Install-Web2View` uses the Installer Products registry branch with string matching; product localization or installer packaging changes may break detection.
- Temp path issues: if `%TEMP%` is redirected or lacks space/permissions, set `TMP`/`TEMP` or pass different paths by editing the script's helpers.
- QuickAssist removal errors: capture the function output and run `Get-WindowsCapability -Online | Where-Object Name -like '*QuickAssist*'` manually to inspect the capability name and state.
- Adobe MST transform errors: ensure the `Transforms` folder exists under the extracted Acrobat installer and that `AcroPro.mst` is valid for the installer version.

## Verification steps
- .NET 4.8: check `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\` for `Version` and `Release` values.
- WebView2: check installed programs or registry under Installer Products for WebView2 entries.
- Chocolatey: run `choco -v` to verify installation.
- Adobe Acrobat: check Add/Remove Programs and run `Acrobat.exe --version` (path depends on install).

## Notes for automation
- When running in CI or image builder environments, prefer hosting installers in a private blob or artifact store.
- Consider adding logging (Start-Transcript) around the provisioning run to capture stdout/stderr for debugging.
- Add timeouts and retries around network downloads for higher reliability.

## Maintenance
- Keep the download URLs up to date. When vendor packages change, verify transform files (MST) and installer command-line switches.
- Consider converting large downloads to cached artifacts on a provisioning server to reduce external dependency during image builds.

## License
This repository and scripts are provided as-is. Review and adapt for your organization's policies and licensing (especially for proprietary software like Adobe Acrobat).

---

If you'd like, I can also:
- Add parameterization to `BaseImageInstall.ps1` so URLs and options are configurable via a small JSON or PowerShell config file.
- Add simple logging wrappers or a `Run-All` function that performs the standard image setup sequence with progress and error handling.

Tell me which of the above extras you want and I'll implement them.