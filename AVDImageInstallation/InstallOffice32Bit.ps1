$TempDirectory = [System.IO.Path]::GetTempPath()
$OfficeInstallDownloadPath = $TempDirectory + 'OfficeInstall'
$ConfigPath = "$OfficeInstallDownloadPath\configuration.xml"

$configXML = @"
<Configuration ID="e457c3aa-e366-4a32-bc8c-c065bc4e1f1a">
<Add OfficeClientEdition="32" Channel="Current">
  <Product ID="O365ProPlusRetail">
    <Language ID="en-us" />
    <ExcludeApp ID="Groove" />
    <ExcludeApp ID="Lync" />
    <ExcludeApp ID="Access" />
  </Product>
  <Product ID="AccessRuntimeRetail">
      <Language ID="en-us" />
    </Product>
</Add>
<Property Name="SharedComputerLicensing" Value="1" />
<Property Name="FORCEAPPSHUTDOWN" Value="FALSE" />
<Property Name="DeviceBasedLicensing" Value="0" />
<Property Name="SCLCacheOverride" Value="0" />
<Updates Enabled="TRUE" />
<RemoveMSI />
<AppSettings>
  <Setup Name="Company" Value="The Hilb Group" />
  <User Key="software\microsoft\office\16.0\common\graphics" Name="disablehardwareacceleration" Value="1" Type="REG_DWORD" App="office16" Id="L_DoNotUseHardwareAcceleration" />
  <User Key="software\microsoft\office\16.0\excel\options" Name="defaultformat" Value="51" Type="REG_DWORD" App="excel16" Id="L_SaveExcelfilesas" />
  <User Key="software\microsoft\office\16.0\powerpoint\options" Name="defaultformat" Value="27" Type="REG_DWORD" App="ppt16" Id="L_SavePowerPointfilesas" />
  <User Key="software\microsoft\office\16.0\word\options" Name="defaultformat" Value="" Type="REG_SZ" App="word16" Id="L_SaveWordfilesas" />
</AppSettings>
<Display Level="Full" AcceptEULA="TRUE" />
</Configuration>
"@

function Get-ODTURL {
  
    [String]$MSWebPage = Invoke-RestMethod 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117'
  
    $MSWebPage | ForEach-Object {
        if ($_ -match 'url=(https://.*officedeploymenttool.*\.exe)') {
            $matches[1]
        }
    }
  
}
  
if (-Not(Test-Path $OfficeInstallDownloadPath )) {
    New-Item -Path $OfficeInstallDownloadPath -ItemType Directory | Out-Null
}

$ODTInstallLink = Get-ODTURL

Write-Verbose 'Downloading the Office Deployment Tool...'
try {
  Invoke-WebRequest -Uri $ODTInstallLink -OutFile "$OfficeInstallDownloadPath\ODTSetup.exe"
}
catch {
  Write-Warning 'There was an error downloading the Office Deployment Tool.'
  Write-Warning 'Please verify the below link is valid:'
  Write-Warning $ODTInstallLink
  exit
}

#Run the Office Deployment Tool setup
try {
    Write-Verbose 'Running the Office Deployment Tool...'
    Start-Process "$OfficeInstallDownloadPath\ODTSetup.exe" -ArgumentList "/quiet /extract:$OfficeInstallDownloadPath" -Wait
  }
  catch {
    Write-Warning 'Error running the Office Deployment Tool. The error is below:'
    Write-Warning $_
  }

$configXML | Out-File $ConfigPath

#Run the O365 install
try {
    Write-Verbose 'Downloading and installing Microsoft 365'
    Start-Process "$OfficeInstallDownloadPath\Setup.exe" -ArgumentList "/configure $ConfigPath" -Wait -PassThru | Out-Null
  }
  catch {
    Write-Warning 'Error running the Office install. The error is below:'
    Write-Warning $_
  }

  #Check if Office 365 suite was installed correctly.
$RegLocations = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$OfficeInstalled = $False
foreach ($Key in (Get-ChildItem $RegLocations) ) {
if ($Key.GetValue('DisplayName') -like '*Microsoft 365*') {
  $OfficeVersionInstalled = $Key.GetValue('DisplayName')
  $OfficeInstalled = $True
}
}
Remove-Item -Path $OfficeInstallDownloadPath -Force -Recurse

if ($OfficeInstalled) {
Write-Verbose "$($OfficeVersionInstalled) installed successfully!"
Exit 0
}
else {
Write-Warning 'Microsoft 365 was not detected after the install ran'
Exit 1
}
