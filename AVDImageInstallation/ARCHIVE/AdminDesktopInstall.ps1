# Enable RSAT ADDS and DNS
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
Add-WindowsCapability -Online -Name 'Rsat.Dns.Tools~~~~0.0.1.0'
Add-WindowsCapability -Online -Name 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'

choco install filezilla -y -Force
choco install rdm -y -Force
choco install mremoteng -y -Force
choco install vscode -y -Force

#Download and Add Barracuda Admin to All Users Desktop