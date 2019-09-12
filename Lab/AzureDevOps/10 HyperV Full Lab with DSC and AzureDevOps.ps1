$labName = 'AllianzDscWorkshop'

#region Lab setup
#--------------------------------------------------------------------------------------------------------------------
#----------------------- CHANGING ANYTHING BEYOND THIS LINE SHOULD NOT BE REQUIRED ----------------------------------
#----------------------- + EXCEPT FOR THE LINES STARTING WITH: REMOVE THE COMMENT TO --------------------------------
#----------------------- + EXCEPT FOR THE LINES CONTAINING A PATH TO AN ISO OR APP   --------------------------------
#--------------------------------------------------------------------------------------------------------------------

#create an empty lab template and define where the lab XML files and the VMs will be stored
New-LabDefinition -Name $labName -DefaultVirtualizationEngine HyperV

#make the network definition
Add-LabVirtualNetworkDefinition -Name $labName -AddressSpace 192.168.112.0/24
Add-LabVirtualNetworkDefinition -Name 'Default Switch' -HyperVProperties @{ SwitchType = 'External'; AdapterName = 'Wi-Fi' }

#and the domain definition with the domain admin account
Add-LabDomainDefinition -Name contoso.com -AdminUser Install -AdminPassword Somepass1

#these credentials are used for connecting to the machines. As this is a lab we use clear-text passwords
Set-LabInstallationCredential -Username Install -Password Somepass1

# Add the reference to our necessary ISO files
Add-LabIsoImageDefinition -Name AzDevOps -Path $labSources\ISOs\azuredevopsserver2019.1.iso #from https://visualstudio.microsoft.com/downloads/
Add-LabIsoImageDefinition -Name SQLServer2017 -Path $labsources\ISOs\SQLServer2017-x64-ENU.iso #from https://www.microsoft.com/en-us/evalcenter/evaluate-sql-server-2017-rtm. The EXE downloads the ISO.

#defining default parameter values, as these ones are the same for all the machines
$PSDefaultParameterValues = @{
    'Add-LabMachineDefinition:Network'         = $labName
    'Add-LabMachineDefinition:ToolsPath'       = "$labSources\Tools"
    'Add-LabMachineDefinition:DomainName'      = 'contoso.com'
    'Add-LabMachineDefinition:DnsServer1'      = '192.168.112.10'
    'Add-LabMachineDefinition:OperatingSystem' = 'Windows Server 2016 Datacenter Evaluation (Desktop Experience)'
    'Add-LabMachineDefinition:Gateway'         = '192.168.112.50'
}

#The PostInstallationActivity is just creating some users
$postInstallActivity = @()
$postInstallActivity += Get-LabPostInstallationActivity -ScriptFileName 'New-ADLabAccounts 2.0.ps1' -DependencyFolder $labSources\PostInstallationActivities\PrepareFirstChildDomain
$postInstallActivity += Get-LabPostInstallationActivity -ScriptFileName PrepareRootDomain.ps1 -DependencyFolder $labSources\PostInstallationActivities\PrepareRootDomain
Add-LabMachineDefinition -Name ADC01 -Memory 1GB -Roles RootDC -IpAddress 192.168.112.10 -PostInstallationActivity $postInstallActivity

#file server and router
$netAdapter = @()
$netAdapter += New-LabNetworkAdapterDefinition -VirtualSwitch $labName -Ipv4Address 192.168.112.50
$netAdapter += New-LabNetworkAdapterDefinition -VirtualSwitch 'Default Switch' -UseDhcp

# The good, the bad and the ugly
Add-LabMachineDefinition -Name ACASQL01 -Memory 3GB -Roles CaRoot, SQLServer2017, Routing -NetworkAdapter $netAdapter

# DSC Pull Server with SQL server backing, TFS Build Worker
$roles = @(
    Get-LabMachineRoleDefinition -Role DSCPullServer -Properties @{
        DoNotPushLocalModules = 'true'
        DatabaseEngine        = 'sql'
        SqlServer             = 'ACASQL01'
        DatabaseName          = 'DSC'
    }
    Get-LabMachineRoleDefinition -Role TfsBuildWorker
    Get-LabMachineRoleDefinition -Role WebServer
)
$proGetRole = Get-LabPostInstallationActivity -CustomRole ProGet5 -Properties @{
    ProGetDownloadLink = 'https://s3.amazonaws.com/cdn.inedo.com/downloads/proget/ProGetSetup5.1.23.exe'
    SqlServer          = 'ACASQL01'
}
Add-LabMachineDefinition -Name APULL01 -Memory 2GB -Roles $roles -IpAddress 192.168.112.60 -PostInstallationActivity $proGetRole -OperatingSystem 'Windows Server 2019 Datacenter (Desktop Experience)'

# Build Server
$roles = @(
    Get-LabMachineRoleDefinition -Role AzDevOps
    Get-LabMachineRoleDefinition -Role TfsBuildWorker
)
Add-LabMachineDefinition -Name ATFS01 -Memory 4GB -Roles $roles -IpAddress 192.168.112.70

# DSC target nodes - our legacy VMs with an existing configuration
# Servers in Dev
Add-LabMachineDefinition -Name AFile01 -Memory 1GB -Roles FileServer -IpAddress 192.168.112.100
Add-LabMachineDefinition -Name AWeb01 -Memory 1GB -Roles WebServer -IpAddress 192.168.112.101

# Servers in Pilot
Add-LabMachineDefinition -Name AFile02 -Memory 1GB -Roles FileServer -IpAddress 192.168.112.110
Add-LabMachineDefinition -Name AWeb02 -Memory 1GB -Roles WebServer -IpAddress 192.168.112.111

# Servers in Prod
Add-LabMachineDefinition -Name AFile03 -Memory 1GB -Roles FileServer -IpAddress 192.168.112.120
Add-LabMachineDefinition -Name AWeb03 -Memory 1GB -Roles WebServer -IpAddress 192.168.112.121

Install-Lab

Enable-LabCertificateAutoenrollment -Computer -User
Install-LabWindowsFeature -ComputerName (Get-LabVM -Role DSCPullServer, FileServer, WebServer, Tfs2018) -FeatureName RSAT-AD-Tools
Install-LabSoftwarePackage -Path $labsources\SoftwarePackages\Notepad++.exe -CommandLine /S -ComputerName (Get-LabVM)

Invoke-LabCommand -ActivityName 'Disable Windows Update service' -ComputerName (Get-LabVM) -ScriptBlock { Stop-Service -Name wuauserv; Set-Service -Name wuauserv -StartupType Disabled }

# in case you screw something up
Write-Host "1. - Creating Snapshot 'AfterInstall'" -ForegroundColor Magenta
Checkpoint-LabVM -All -SnapshotName AfterInstall
#endregion

Show-LabDeploymentSummary -Detailed