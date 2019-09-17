﻿#Requires -Version 5
#Requires -Module Az.Accounts, Az.Compute, Az.Network, Az.Storage, Az.Resources

<#
    Name        : Move-AzVmToRegion.ps1
    Version     : 1.0.0.2
    Last Update : 2019/09/17
    Keywords	: Azure, VM, Move
    Created by  : Martin Schvartzman, Microsoft
    Description	: This script moves a virtual machine and all it's dependencies to a different region
    Process     :
                    1. Verify target region can contain the VM size
                    2. Create the target resource group if needed
                    3. Read the VM's networking configuration
                    4. Stop the virtual machine
                    5. Create a temp storage account and vhds container in the target region
                    6. Export the managed disks as SAS url
                    7. Copy the disks (VHD files) to the temp storage account
                    8. Create new managed disks from the vhds
                    9. Create the networking components (vnet, subnet, NSG, IP, etc.)
                    6. Recreate the virtual machine
    Todo        :
                    1. Handle diagnostic settings and it's storage account
                    2. Better error handling and logging
#>

function Move-AzVmToRegion {


    [CmdletBinding(SupportsShouldProcess = $true)]

    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachineList] $VM,

        [Parameter(Mandatory = $true)] $TargetLocation,

        [Parameter(Mandatory = $true)] $TargetResourceGroup,

        [int]    $SasTokenDuration = 3600,
        [string] $StorageType = 'Premium_LRS',
        [string] $AzCopyPath = '.\azcopy.exe',
        [switch] $UseAzCopy
    )

    #region Location
    Write-Verbose -Message ('{0:HH:mm:ss} - Verifying target location' -f (Get-Date))
    $locations = Get-AzLocation | Where-Object { $_.Providers -contains 'Microsoft.Compute' }
    if ($TargetLocation -match '\s') {
        $TargetLocation = @($locations | Where-Object { $_.DisplayName -eq $TargetLocation } | Select-Object -ExpandProperty Location)[0]
    } else {
        $TargetLocation = @($locations.Location -match $TargetLocation)[0]
    }

    if (-not $TargetLocation) {
        Write-Warning 'Target location error. Process aborted.'
        break
    }

    if ($VM.Location -eq $TargetLocation) {
        Write-Warning 'Source and target location are the same. Process aborted.'
        break
    }

    Write-Verbose -Message ('{0:HH:mm:ss} - Checking size availability in the target region' -f (Get-Date))
    $sizes = Get-AzVMSize -Location $TargetLocation | Select-Object -ExpandProperty Name
    if ($sizes -notcontains $VM.HardwareProfile.VmSize) {
        Write-Warning 'Target location doesnt support the VM size. Process aborted.'
        break
    }
    #endregion


    #region verify copy mode
    if ($UseAzCopy -and (-not (Test-Path -Path $AzCopyPath))) {
        Write-Warning 'AzCopy.exe was not found in the specified path. The Start-AzStorageBlobCopy cmdlet will be used instead'
        $UseAzCopy = $false
    }
    #endregion


    if ($PSCmdlet.ShouldProcess($VM.Name, "Move to $TargetLocation")) {

        #region ResourceGroup
        Write-Verbose -Message ('{0:HH:mm:ss} - Verifying the resource group' -f (Get-Date))
        if (-not $TargetResourceGroup) {
            $TargetResourceGroup = '{0}-new' -f $VM.ResourceGroupName
        }
        if (-not (Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue)) {
            New-AzResourceGroup -Name $TargetResourceGroup -Location $TargetLocation -Force | Out-Null
        }
        #endregion


        #region Networking
        Write-Verbose -Message ('{0:HH:mm:ss} - Collecting network configuration' -f (Get-Date))
        $nic = Get-AzNetworkInterface -ResourceId $VM.NetworkProfile.NetworkInterfaces.Id
        $pubIp = Get-AzPublicIpAddress | Where-Object { $_.Id -eq $nic.IpConfigurations.PublicIpAddress.Id }
        $nsg = Get-AzNetworkSecurityGroup | Where-Object { $_.Id -eq $nic.NetworkSecurityGroup.Id }
        $vnetName = $nic.IpConfigurations[0].Subnet.Id -replace '.*\/virtualNetworks\/(.*)\/subnets\/.*', '$1'
        $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $VM.ResourceGroupName
        $targetVnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
        #endregion


        #region VM Status
        Write-Verbose -Message ('{0:HH:mm:ss} - Verifying VM is shutdown' -f (Get-Date))
        $vmStatus = $VM | Get-AzVM -Status
        if ($vmStatus.PowerState -ne 'VM deallocated') {
            $VM | Stop-AzVM -Force | Out-Null
        }
        #endregion


        #region Create a temp target storage account and container
        Write-Verbose -Message ('{0:HH:mm:ss} - Creating a temporary storage account' -f (Get-Date))
        $storageAccountParams = @{
            ResourceGroupName = $TargetResourceGroup
            Location          = $TargetLocation
            SkuName           = $StorageType
            Name              = 'tempstrg{0:yyyyMMddHHmmssff}' -f (Get-Date)
        }; $targetStorage = New-AzStorageAccount @storageAccountParams

        Write-Verbose -Message ('{0:HH:mm:ss} - Creating the target container' -f (Get-Date))
        $storageContextParams = @{
            StorageAccountName = $targetStorage.StorageAccountName
            StorageAccountKey  = (
                Get-AzStorageAccountKey -ResourceGroupName $targetStorage.ResourceGroupName -Name $targetStorage.StorageAccountName
            )[0].Value
        }; $storageContext = New-AzStorageContext @storageContextParams
        New-AzStorageContainer -Name vhds -Context $storageContext | Out-Null
        #endregion


        #region Export the managed disks
        Write-Verbose -Message ('{0:HH:mm:ss} - Generating SASAccess for the OSDisk' -f (Get-Date))
        $osDiskAccessParams = @{
            ResourceGroupName = $vm.ResourceGroupName
            DiskName          = $vm.StorageProfile.OsDisk.Name
            DurationInSecond  = $SasTokenDuration
            Access            = 'Read'
        }; $osDiskSAS = Grant-AzDiskAccess @osDiskAccessParams

        $sourceDataDisks = $vm.StorageProfile.DataDisks
        $dataDisksSAS = @{ }
        foreach ($dataDisk in $sourceDataDisks) {
            Write-Verbose -Message ('{0:HH:mm:ss} - Generating SASAccess for DataDisk: {1}' -f (Get-Date), $dataDisk.Name)
            $dataDiskAccessParams = @{
                ResourceGroupName = $vm.ResourceGroupName
                DiskName          = $dataDisk.Name
                DurationInSecond  = $SasTokenDuration
                Access            = 'Read'
            }; $dataDisksSAS.Add($dataDisk.Name, (Grant-AzDiskAccess @dataDiskAccessParams))
        }
        #endregion


        #region Copy the vhds
        Write-Verbose -Message ('{0:HH:mm:ss} - Copying the vhds to the target container' -f (Get-Date))
        function Copy-ManagedDiskToTargetContainer {
            param(
                $storageContext,
                $AccessSAS,
                $DestinationBlob,
                [switch]$useAzCopy
            )
            if ($useAzCopy) {
                $storageSasParams = @{
                    Context    = $storageContext
                    ExpiryTime = (Get-Date).AddSeconds($SasTokenDuration)
                    FullUri    = $true
                    Name       = 'vhds'
                    Permission = 'rw'
                }
                $targetContainer = New-AzStorageContainerSASToken @storageSasParams
                $azCopyArgs = @('copy', $AccessSAS, $targetContainer)
                Start-Process -FilePath $AzCopyPath -ArgumentList $azCopyArgs -Wait
            } else {
                $blobCopyParams = @{
                    AbsoluteUri   = $AccessSAS
                    DestContainer = 'vhds'
                    DestContext   = $storageContext
                    DestBlob      = $DestinationBlob
                }
                Start-AzStorageBlobCopy @blobCopyParams | Out-Null
                do {
                    Start-Sleep -Seconds 30
                    $copyState = Get-AzStorageBlobCopyState -Blob $blobCopyParams.DestBlob -Container 'vhds' -Context $storageContext
                    $progress = [Math]::Round((($copyState.BytesCopied / $copyState.TotalBytes) * 100))
                    Write-Host ('WAITING: {0:HH:mm:ss} - Waiting for the {1} blob copy process to complete ({2} %)' -f (Get-Date), $DestinationBlob, $progress) -ForegroundColor Yellow
                } until ($copyState.Status -ne [Microsoft.Azure.Storage.Blob.CopyStatus]::Pending)
            }
        }

        Copy-ManagedDiskToTargetContainer -storageContext $storageContext -AccessSAS $osDiskSAS.AccessSAS -DestinationBlob ('{0}_OsDisk.vhd' -f $VM.Name)
        $dataDisksSAS.GetEnumerator() | ForEach-Object {
            Copy-ManagedDiskToTargetContainer -storageContext $storageContext -AccessSAS $_.Value.AccessSAS -DestinationBlob ('{0}.vhd' -f $_.Key)
        }
        #endregion


        #region Create the new managed disks
        Write-Verbose -Message ('{0:HH:mm:ss} - Creating the new OS managed disk from the vhd' -f (Get-Date))
        $newDiskConfigParams = @{
            AccountType      = $StorageType
            Location         = $TargetLocation
            CreateOption     = 'Import'
            StorageAccountId = $targetStorage.Id
            OsType           = $vm.StorageProfile.OsDisk.OsType
            SourceUri        = 'https://{0}.blob.core.windows.net/vhds/{1}_OsDisk.vhd' -f $targetStorage.StorageAccountName, $VM.Name
        }; $newOsDiskConfig = New-AzDiskConfig @newDiskConfigParams

        $newDiskParams = @{
            Disk              = $newOsDiskConfig
            ResourceGroupName = $TargetResourceGroup
            DiskName          = ('{0}_OsDisk' -f $VM.Name)
        }; $newOsDisk = New-AzDisk @newDiskParams

        Write-Verbose -Message ('{0:HH:mm:ss} - Creating the new data managed disks from the vhds' -f (Get-Date))
        $newDataDisks = @()
        foreach ($dataDisk in $sourceDataDisks) {
            Write-Verbose -Message ('{0:HH:mm:ss} - Generating data managed disk: {1}' -f (Get-Date), $dataDisk.Name)
            $newDiskConfigParams = @{
                AccountType      = $datadisk.ManagedDisk.StorageAccountType
                Location         = $TargetLocation
                CreateOption     = 'Import'
                StorageAccountId = $targetStorage.Id
                SourceUri        = 'https://{0}.blob.core.windows.net/vhds/{1}.vhd' -f $targetStorage.StorageAccountName, $dataDisk.Name
            }; $newDataDiskConfig = New-AzDiskConfig @newDiskConfigParams
            $newDiskParams = @{
                Disk              = $newDataDiskConfig
                ResourceGroupName = $TargetResourceGroup
                DiskName          = $dataDisk.Name
            }; $newDataDisks += New-AzDisk @newDiskParams
        }
        #endregion


        #region Create the new VM (networking, disks, etc.)
        Write-Verbose -Message ('{0:HH:mm:ss} - Creating the new VM config' -f (Get-Date))
        $vmConfigParams = @{
            VMName      = $VM.Name
            VMSize      = $VM.HardwareProfile.VmSize
            LicenseType = $VM.LicenseType
            Tags        = $VM.Tags
        }; $newVmConfig = New-AzVMConfig @vmConfigParams

        $newVmConfig.FullyQualifiedDomainName = $VM.FullyQualifiedDomainName
        $newVmConfig.Location = $TargetLocation
        if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') {
            $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows
        } else {
            $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux
        }

        for ($i = 0; $i -lt $newDataDisks.Count; $i++) {
            $sourceDataDisk = $sourceDataDisks | Where-Object { $_.Name -eq $newDataDisks[$i].Name }
            $newDataDiskAttachConfig = @{
                Lun                = $i
                CreateOption       = 'Attach'
                Name               = $newDataDisks[$i].Name
                ManagedDiskId      = $newDataDisks[$i].Id
                Caching            = $sourceDataDisk.Caching
                StorageAccountType = $sourceDataDisk.ManagedDisk.StorageAccountType
            }
            $newVmConfig = Add-AzVMDataDisk -VM $newVmConfig @newDataDiskAttachConfig
        }


        #region Networking
        Write-Verbose -Message ('{0:HH:mm:ss} - Verifying network configuration' -f (Get-Date))
        $targetSubnetName = $nic.IpConfigurations[0].Subnet.Id -replace '.*\/(\w+)$', '$1'
        if (-not $targetVnet) {
            $newSubnets = $vnet.Subnets | ForEach-Object {
                $newSubnetParams = @{
                    Name          = $_.Name
                    AddressPrefix = $_.AddressPrefix
                }
                if ($_.NetworkSecurityGroup) {
                    $newNsgParams = @{
                        Name              = $_.NetworkSecurityGroup.Name
                        ResourceGroupName = $TargetResourceGroup
                        Location          = $TargetLocation
                        SecurityRules     = $_.NetworkSecurityGroup.SecurityRules
                        Tag               = $_.NetworkSecurityGroup.Tag
                    }
                    $newNSG = New-AzNetworkSecurityGroup @newNsgParams
                    $newSubnetParams.Add('NetworkSecurityGroup', $newNSG)
                }
                New-AzVirtualNetworkSubnetConfig @newSubnetParams
            }

            $newVnetParams = @{
                Name              = $vnetName
                ResourceGroupName = $TargetResourceGroup
                Location          = $TargetLocation
                AddressPrefix     = $vnet.AddressSpace.AddressPrefixes
                Subnet            = $newSubnets
                Tag               = $vnet.Tag
            }
            if ($vnet.DhcpOptions) { $newVnetParams.Add('DnsServer', $vnet.DhcpOptions.DnsServers) }
            if ($vnet.EnableDdosProtection) {
                $newVnetParams.Add('EnableDdosProtection', $vnet.EnableDdosProtection)
                $newVnetParams.Add('DdosProtectionPlanId', $vnet.DdosProtectionPlan)
            }
            $newVnet = New-AzVirtualNetwork @newVnetParams
            $targetSubnetId = $newVnet.Subnets | Where-Object { $_.Name -eq $targetSubnetName } | Select-Object -ExpandProperty Id
        } else {
            $targetSubnetId = $targetVnet.Subnets | Where-Object { $_.Name -eq $targetSubnetName } | Select-Object -ExpandProperty Id
        }

        $newNicParams = @{
            Name              = $nic.Name
            ResourceGroupName = $TargetResourceGroup
            Location          = $TargetLocation
            SubnetId          = $targetSubnetId
        }
        $newNic = New-AzNetworkInterface @newNicParams

        if ($nsg) {
            $newNsgParams = @{
                Name              = $nsg.Name
                ResourceGroupName = $TargetResourceGroup
                Location          = $TargetLocation
                SecurityRules     = $nsg.SecurityRules
                Tag               = $nsg.Tag
            }
            $newNSG = New-AzNetworkSecurityGroup @newNsgParams
            $newNic.NetworkSecurityGroup = $newNSG
            $newNic = $newNic | Set-AzNetworkInterface
        }

        if ($pubIp) {
            Write-Verbose -Message ('{0:HH:mm:ss} - Creating the new public IP' -f (Get-Date))
            $newPubIpParams = @{
                Name                 = $pubIp.Name
                ResourceGroupName    = $TargetResourceGroup
                Location             = $TargetLocation
                AllocationMethod     = $pubIp.PublicIpAllocationMethod
                DomainNameLabel      = $pubIp.DnsSettings.DomainNameLabel
                Sku                  = $pubIp.Sku.Name
                IdleTimeoutInMinutes = $pubIp.IdleTimeoutInMinutes
                IpAddressVersion     = $pubIp.PublicIpAddressVersion
                Tag                  = $pubIp.Tag
            }
            $newPubIp = New-AzPublicIpAddress @newPubIpParams
            $newIpConfig = ($pubIp.IpConfiguration.Id -split '/')[-1]
            do { Start-Sleep -Seconds 2 } while ((-not (Get-AzPublicIpAddress | Where-Object { $_.Id -eq $newPubIp.Id })))
            $newNic = $newNic | Set-AzNetworkInterfaceIpConfig -Name $newIpConfig -PublicIpAddress $newPubIp | Set-AzNetworkInterface
        }

        $newVmConfig = $newVmConfig | Add-AzVMNetworkInterface -Id $newNic.Id
        #endregion


        Write-Verbose -Message ('{0:HH:mm:ss} - Creating the VM' -f (Get-Date))
        $newVmConfig | New-AzVM -Location $TargetLocation -ResourceGroupName $TargetResourceGroup
        #endregion

    }
}



# Login-AzAccount
$TargetLocation = 'north europe'
$TargetResourceGroup = 'rg-vms-northeurope'
$vm = Get-AzVM -ResourceGroupName 'rg-test-vms' -Name 'akada-vm'
$vm | Move-AzVmToRegion -TargetLocation 'north europe' -TargetResourceGroup 'rg-vms-northeurope' -Verbose