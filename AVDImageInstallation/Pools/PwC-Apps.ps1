$ProgressPreference = 'SilentlyContinue'

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

function Install-WorkdayStudio {
	$WDStudioUrl = "https://studio.myworkdaygadgets.com/downloads/workday-studio-x86_64.exe"

	Invoke-DownloadAndStartProcess -DownloadURL $WDStudioUrl -FileName "WDStudio.exe" -Arguments "/S /J=C:\Program Files\Zulu\zulu-17 /RD /D=$($env:APPDATA)\Studio"
}

function Install-Postman {
	$PostmanUrl = "https://dl.pstmn.io/download/latest/win64"

	Invoke-DownloadAndStartProcess -DownloadURL $PostmanUrl -FileName "Postman.exe" -Arguments ""
}


Write-Output "Installing Workday Studio..."
Install-WorkdayStudio

Write-Output "Installing Postman..."
Install-Postman