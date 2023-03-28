#Connect to Azure AD
connect-azaccount

#Sets location for all resources to variable
$Location = 'West US 3'

#import CSV file
$AzureCSV = import-csv $psscriptroot\azurecsv.csv

#Sets AZ subscription
set-azcontext -subscription ([string]$azurecsv.subscription)


#Registers all necessary resource providers
write-host "Registering Resource Providers"
register-azresourceprovider -providernamespace Microsoft.Network
register-azresourceprovider -providernamespace Microsoft.compute
register-azresourceprovider -providernamespace Microsoft.security
register-azresourceprovider -providernamespace Microsoft.Storage


# Create a new resource group
Write-host "Creating resource group"
$acronym=([string]$azurecsv.clientacronym[0])
$Resourcegroup = ([string]$acronym+'-RG')
New-AzResourceGroup -Name $resourcegroup -Location $Location

#Create NSG
Write-host "Creating network security group"

$NetworkSG = New-AzNetworkSecurityGroup -ResourceGroupName $resourcegroup -Location $Location -Name ([string]$acronym+'-VNET-SN-NSG')

#Create Subnet and attaches NSG
Write-host "Creating virtual network"
$SubnetConfig = New-AzVirtualNetworkSubnetConfig -Name ([string]$acronym+'-VNET-SN') -AddressPrefix ($azurecsv.subnetrange[0]) -NetworkSecurityGroupId $NetworkSG.Id
$GatewaySubnetConfig = New-AzVirtualNetworkSubnetConfig -name GatewaySubnet -AddressPrefix ($azurecsv.gatewaysubnet[0]) 

#Create Virtual Network
$VirtualNetwork = New-AzVirtualNetwork -ResourceGroupName $resourcegroup -Location $Location -Name ([string]$acronym +'-VNET') -AddressPrefix ($azurecsv.vnetrange[0]) -Subnet $SubnetConfig,$gatewaysubnetconfig 

#loop through VMs in CSV file and create VMs. This will check VM names and create and attach datadisk.
Foreach ($item in $azurecsv)
{ 
if($item.vmname -ne ""){
    #Create NIC
    Write-host "Creating network interface card"
    $NetworkInterface = New-AzNetworkInterface -Name ($item.vmname +'-NIC') -ResourceGroupName $resourcegroup -Location $Location -SubnetId $VirtualNetwork.Subnets[0].Id 

    #Create Virtual Machine.
    write-host "Creating Virtual Machines"

    #Creates password credential
    $Username = ($azurecsv.username[0]) 
    $Password = ($azurecsv.password[0] | ConvertTo-SecureString -force -asplaintext)
    $Credential = New-Object -TypeName PSCredential -ArgumentList ($Username, $Password)

    #Create the virtual machine configuration objects
    write-host "Creating VM objects"
    $VirtualMachine = New-AzVMConfig -VMName $item.vmname -VMSize $item.vmsize
    $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $item.vmname -Credential $Credential -ProvisionVMAgent -EnableAutoUpdate -Patchmode Automaticbyplatform
    $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $Networkinterface.Id
    $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus "2022-Datacenter-Azure-Edition" -Version 'latest'

    #Actually creates the virtual machine
    New-AzVM -ResourceGroupName $resourcegroup -Location $Location -VM $VirtualMachine -Verbose

    #Checks computer name to see if a data disk is needed. 
    write-host "Checking for data disk"
    If ($item.disksize -ne "")
    {
        #Creates datadisk then attaches it to VM.
        Write-host "Creating and attaching data disk"
        $datadiskname = ($item.vmname +'_Datadisk')
        $diskConfig = New-AzDiskConfig -SkuName Premium_LRS -Location $location -CreateOption Empty -DiskSizeGB ($item.disksize)
        $dataDisk1 = New-AzDisk -DiskName $datadiskname -Disk $diskConfig -ResourceGroupName $resourcegroup

        $vm = Get-AzVM -Name $item.vmname -ResourceGroupName $resourcegroup
        $vm = Add-AzVMDataDisk -VM $vm -Name $dataDiskName -CreateOption Attach -ManagedDiskId $dataDisk1.Id -Lun 1

        Update-AzVM -VM $vm -ResourceGroupName $resourcegroup
    }
}
}

#Creates Virtual Network Gateway
Write-host "Creating Virtual Network Gateway. This will take a while. Up to 30 minutes is not unusual"
$ngwpip = New-AzPublicIpAddress -Name VNG-PIP -ResourceGroupName $resourcegroup -Sku "Standard" -Location $Location -AllocationMethod Static
$gatewaysubnet = Get-AzVirtualNetworkSubnetConfig -name 'gatewaysubnet' -VirtualNetwork $VirtualNetwork
$ngwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name ngwipconfig -SubnetId $gatewaysubnet.Id -PublicIpAddressId $ngwpip.Id
New-AzVirtualNetworkGateway -Name ([string]$acronym+'-VNG') -ResourceGroupName $resourcegroup -Location $location -IpConfigurations $ngwIpConfig  -GatewayType "Vpn" -VpnType "RouteBased" -GatewaySku ([string]$azurecsv.VNGSKU[0])

#Creates Local Network Gateway. This is stupid.
Write-host "Creating Local Network Gateway" 
if ($Azurecsv.LNGSubnet[1] -eq "")
{
    New-AzLocalNetworkGateway -Name ([string]$acronym+'-LNG') -ResourceGroupName $resourcegroup -Location $location -GatewayIpAddress ($azurecsv.LNGIP[0]) -AddressPrefix ([string]$Azurecsv.LNGSubnet[0])
}
elseif ($azurecsv.LNGSubnet[2] -eq "")
{
    New-AzLocalNetworkGateway -Name ([string]$acronym+'-LNG') -ResourceGroupName $resourcegroup -Location $location -GatewayIpAddress ($azurecsv.LNGIP[0]) -AddressPrefix ([string]$Azurecsv.LNGSubnet[0],[string]$azurecsv.LNGSubnet[1])
}
else 
{
    New-AzLocalNetworkGateway -Name ([string]$acronym+'-LNG') -ResourceGroupName $resourcegroup -Location $location -GatewayIpAddress ($azurecsv.LNGIP[0]) -AddressPrefix ([string]$Azurecsv.LNGSubnet[0],[string]$azurecsv.LNGSubnet[1],[string]$azurecsv.LNGSubnet[2])
}

#Creates default VPN Connection. 
$virtualgateway = Get-AzVirtualNetworkGateway -Name ([string]$acronym+'-VNG') -ResourceGroupName $resourcegroup
$localgateway = Get-AzLocalNetworkGateway -Name ([string]$acronym+'-LNG') -ResourceGroupName $resourcegroup
New-AzVirtualNetworkGatewayConnection -Name ([string]$acronym+'-VPN-MainOffice') -ResourceGroupName $resourcegroup -Location $location -VirtualNetworkGateway1 $virtualgateway -LocalNetworkGateway2 $localgateway -ConnectionType IPsec -SharedKey ([string]$azurecsv.sharedsecretkey)

#Creates Nat Gateway
write-host "Creating Nat Gateway"
$ngwpip = New-AzPublicIpAddress -Name NGW-PIP -ResourceGroupName $resourcegroup -Sku "Standard" -Location $Location -AllocationMethod Static
$natgateway = New-AzNatGateway -ResourceGroupName ([string]$resourcegroup) -Name ([string]$acronym+'-NGW') -IdleTimeoutInMinutes 5 -Sku "Standard" -Location $location -PublicIpAddress $ngwpip
$vnet = get-azvirtualnetwork -name ([String]$Acronym +'-VNET') -resourcegroupname $resourcegroup
$subnet = get-azvirtualnetworksubnetconfig -name ([string]$acronym+'-VNET-SN') -virtualnetwork $vnet
$subnet.NatGateway = $natgateway
$vnet | set-azvirtualnetwork

Read-host "press enter to end script"
