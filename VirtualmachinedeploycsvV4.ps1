#Connect to Azure AD
connect-azaccount
#Sets location for all resources to variable
$Location = 'East US'
#import CSV file
$AzureCSV = import-csv $psscriptroot\azurecsv.csv
#Create variables from CSV file
$RGName = ($azurecsv.rgname[0])
$SubnetName = ($azurecsv.subnetname[0])
$SubnetRange = ($azurecsv.subnetrange[0])
$VNetName = ($azurecsv.vnetname[0])
$VNetRange = ($azurecsv.vnetrange[0])
$NSGName = ($subnetname + '-NSG')
$Username = ($azurecsv.username[0]) 
$Password = ($azurecsv.password[0] | ConvertTo-SecureString -force -asplaintext)
$Securitygrouprule = (New-AzNetworkSecurityRuleConfig -Name "RDP-Rule" -Description "Allow RDP" -Access "Allow" -Protocol "TCP" -Direction "Inbound" -Priority 100 -DestinationPortRange 3389 -SourceAddressPrefix "*" -SourcePortRange "*" -DestinationAddressPrefix "*" )

# Create a new resource group
Write-host "Creating resource group"
New-AzResourceGroup -Name $RGName -Location $Location

#Create NSG
Write-host "Creating network security group"
$NetworkSG = New-AzNetworkSecurityGroup -ResourceGroupName $RGName -Location $Location -Name $NSGName -SecurityRules $SecurityGroupRule

#Create Subnet and attaches NSG
Write-host "Creating virtual network"
$SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetRange -NetworkSecurityGroupId $NetworkSG.Id

#Create Virtual Network
$VirtualNetwork = New-AzVirtualNetwork -ResourceGroupName $RGName -Location $Location -Name $VNetName -AddressPrefix $VNetRange -Subnet $SubnetConfig

#loop through VMs in CSV file and create VMs. This will check VM names and create and attach datadisk.
Foreach ($item in $azurecsv)
{ 
    
#Create Public IP 
Write-host "Creating public IP address"
$PublicIP = New-AzPublicIpAddress -ResourceGroupName $RGName -Location $Location -AllocationMethod "Dynamic" -Name ($item.vmname + '-PIP')

#Create NIC
Write-host "Creating network interface card"
$NetworkInterface = New-AzNetworkInterface -Name ($item.vmname + '-NIC') -ResourceGroupName $RGName -Location $Location -SubnetId $VirtualNetwork.Subnets[0].Id -PublicIpAddressId $PublicIP.Id 

#Create Virtual Machine.
write-host "Creating Virtual Machines"

#Creates password credential
$Credential = New-Object -TypeName PSCredential -ArgumentList ($Username, $Password)

# Create the virtual machine configuration objects
write-host "creating VM objects"
$VirtualMachine = New-AzVMConfig -VMName $item.vmname -VMSize $item.vmsize
$VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $item.vmname -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate -Patchmode Automaticbyplatform
$VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $Networkinterface.Id
$VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2016-Datacenter' -Version 'latest'

#Actually creates the virtual machine
New-AzVM -ResourceGroupName $RGName -Location $Location -VM $VirtualMachine -Verbose

#Checks computer name to see if a data disk is needed. 
write-host "Checking computer name to attach data disk"
If ($item.vmname.contains("fs") -or $item.vmname.contains("sql") -or $item.vmname.contains("app"))
{
#Creates datadisk then attaches it to VM.
Write-host "Creating and attaching data disk"
$datadiskname = ($item.vmname + '_Datadisk')
$diskConfig = New-AzDiskConfig -SkuName Standard_LRS -Location $location -CreateOption Empty -DiskSizeGB ($item.disksize)
$dataDisk1 = New-AzDisk -DiskName $datadiskname -Disk $diskConfig -ResourceGroupName $rgName

$vm = Get-AzVM -Name $item.vmname -ResourceGroupName $rgName
$vm = Add-AzVMDataDisk -VM $vm -Name $dataDiskName -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun 1

Update-AzVM -VM $vm -ResourceGroupName $rgName
}
else 
{
    continue
}
}