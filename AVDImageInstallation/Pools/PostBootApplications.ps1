function Get-TempFilePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    $TempDirectory = [System.IO.Path]::GetTempPath()
    return (Join-Path -Path $TempDirectory -ChildPath $FileName)
}

function Invoke-DownloadAndStartProcess {
    param (
        [string]$DownloadURL,
        [string]$FileName,
        [string]$Arguments
    )
    $ProgressPreference = 'SilentlyContinue'
    $TempFilePath = Get-TempFilePath -FileName $FileName
    Invoke-WebRequest -Uri $DownloadURL -OutFile $TempFilePath
    $ProgressPreference = 'Continue'
    Start-Process $TempFilePath -ArgumentList $Arguments -Wait
}

function Install-Qualys {
    $ActivationID = "fa0969cf-7264-45bf-be34-52632dcca96f"
    $CustomerID = "0fc184d4-664e-73f8-82c6-ef818818f7ca"
    $WebURI = "https://qagpublic.qg3.apps.qualys.com/CloudAgent/"
    $Arguments = "CustomerID={" + $CustomerID + "} ActivationId={" + $ActivationID + "} WebServiceUri=" + $WebURI
    $DownloadURL = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/CloudAgent_x64.msi"

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName "CloudAgent_x64.msi" -Arguments $Arguments
}

function Install-NetSkope {
    $Arguments = 'token=e6cFeDnQ3Kw38C54KNiy host=addon-hilbgroup.goskope.com mode=peruserconfig autoupdate=on enrollauthtoken=1ed082ef63c3e4a434b7118a3de92876 enrollencryptiontoken=2e48fb92442ba1677a33772ea62f5268 /qn /l*v C:\hilb\nscinstall.log'
    $DownloadURL = 'https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/NSClient.msi'

    Invoke-DownloadAndStartProcess -DownloadURL $DownloadURL -FileName 'NSClient.msi' -Arguments $arguments
}

function Install-SentinelOne {

    $S1URL64 = "https://eusthginfrastructure.blob.core.windows.net/thg-software-deploy/S1.msi"
    $S1File64 = "S1.msi"
    $Arguments = '/q /norestart SITE_TOKEN="eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1jc3MtczEwMS5zZW50aW5lbG9uZS5uZXQiLCAic2l0ZV9rZXkiOiAiYTljNDJjYzYxNDUzM2NkNyJ9"'

    Invoke-DownloadAndStartProcess -DownloadURL $S1URL64 -FileName $S1File64 -Arguments $Arguments
}

function Install-WorkdayOfficeConnect {
    $url = "https://clickonce.adaptiveinsights.com/officeconnect/latest/OfficeConnectMachineSetup.exe"

    Invoke-DownloadAndStartProcess -DownloadURL $url -FileName "OfficeConnectMachineSetup.exe" -Arguments "/quiet"
}

function Set-FSLogixBypassGroups {
    Add-LocalGroupMember -Group "FSLogix ODFC Exclude List" -Member "localadmin" -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "FSLogix Profile Exclude List" -Member "localadmin" -ErrorAction SilentlyContinue

    Add-LocalGroupMember -Group "FSLogix ODFC Exclude List" -Member  "HILBGROUP\AVD_Users_HILB_L2" -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "FSLogix Profile Exclude List" -Member  "HILBGROUP\AVD_Users_HILB_L2" -ErrorAction SilentlyContinue

    Add-LocalGroupMember -Group "FSLogix ODFC Exclude List" -Member  "HILBGROUP\Azure Administrators" -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "FSLogix Profile Exclude List" -Member "HILBGROUP\Azure Administrators" -ErrorAction SilentlyContinue
}

function Set-TimeZoneToEST {
    Set-TimeZone -Id "US Eastern Standard Time"
}

function Set-IRFolderPermissions {
    $FolderPath = "C:\Program Files (x86)\ImageRight"
    $Group = "HILBGROUP\AVDUsers"

    $ACL = Get-ACL $FolderPath

    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Group,
        "FullControl",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )

    $acl.AddAccessRule($accessRule)

    Set-Acl -Path $FolderPath -AclObject $acl
}


Install-Qualys

Install-NetSkope

Install-SentinelOne

Install-WorkdayOfficeConnect

Set-FSLogixBypassGroups

Set-TimeZoneToEST

Set-IRFolderPermissions