#!/bin/bash

# VARIABLES
rg=pls-public
loc=eastus

BLACK="\033[30m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PINK="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
NORMAL="\033[0;39m"

usessh="true"
vmapp="appVM"
username="azureuser"
password="MyP@ssword123"
vmsize="Standard_D2S_v3"

echo -e "$WHITE$(date +"%T")$GREEN Creating Resource Group$CYAN" $rg"$GREEN in $CYAN"$loc"$WHITE"
 az group create \
    --name $rg \
    --location $loc \
    -o none

# ======================================================
# create Private Link Service

echo -e "$WHITE$(date +"%T")$GREEN Creating Private Link Service ..... $WHITE"

echo -e "$WHITE$(date +"%T")$GREEN Creating Virtual Network plsVnet $WHITE"
az network vnet create \
    --resource-group $rg \
    --location $loc \
    --name plsVnet \
    --address-prefixes 10.1.0.0/16 \
    --subnet-name app \
    --subnet-prefixes 10.1.0.0/24 \
    -o none

echo -e ".... creating bastion subnet"
az network vnet subnet create \
    --resource-group $rg \
    --name AzureBastionSubnet \
    --vnet-name plsVnet \
    --address-prefixes 10.1.5.0/24 \
    -o none

echo -e ".... turn off pls network policy"
az network vnet subnet update \
    --name app \
    --resource-group $rg \
    --vnet-name plsVnet \
    --disable-private-link-service-network-policies true \
    -o none

echo -e "$WHITE$(date +"%T")$GREEN Create pls load balancer $WHITE"
az network lb create \
    --resource-group $rg \
    --name serviceLB \
    --sku Standard \
    --vnet-name plsVnet \
    --subnet app \
    --frontend-ip-name frontend \
    --backend-pool-name bepool1 \
    --only-show-errors \
    -o none

echo -e ".... create lb probe"
az network lb probe create \
    --resource-group $rg \
    --lb-name serviceLB \
    --name probe1 \
    --protocol tcp \
    --port 80 \
    -o none

echo -e ".... create lb rule"
az network lb rule create \
    --resource-group $rg \
    --lb-name serviceLB \
    --name httprule1 \
    --protocol tcp \
    --frontend-port 80 \
    --backend-port 80 \
    --frontend-ip-name frontend \
    --backend-pool-name bepool1 \
    --probe-name probe1 \
    --idle-timeout 15 \
    --enable-tcp-reset true \
    -o none

echo -e "$WHITE$(date +"%T")$GREEN Create Private Link Service (pls) $WHITE"
az network private-link-service create \
    --resource-group $rg \
    --name plService \
    --vnet-name plsVnet \
    --subnet app \
    --lb-name serviceLB \
    --lb-frontend-ip-configs frontend \
    --location $loc \
    -o none

# Create bastion to support access to other VM's that are not reachable publicly
echo -e "$WHITE$(date +"%T")$GREEN Creating Bastion $WHITE"
az network public-ip create --name bastion-pip --resource-group $rg -l $loc --sku Standard -o none --only-show-errors
az network bastion create -g $rg -n bastion --public-ip-address bastion-pip --vnet-name plsVnet -l $loc -o none --only-show-errors

# Turn on SSH tunneling
# az cli does not have a property to enable SSH tunneling, so must be done via rest API
echo -e "$WHITE$(date +"%T")$GREEN Turn on SSH Tunneling $WHITE"
subid=$(az account show --query 'id' -o tsv)
uri='https://management.azure.com/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/bastionHosts/bastion?api-version=2021-08-01'
json='{
  "location": "'$loc'",
  "properties": {
    "enableTunneling": "true",
    "ipConfigurations": [
      {
        "name": "bastion_ip_config",
        "properties": {
          "subnet": {
            "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/virtualNetworks/plsVnet/subnets/AzureBastionSubnet"
          },
          "publicIPAddress": {
            "id": "/subscriptions/'$subid'/resourceGroups/'$rg'/providers/Microsoft.Network/publicIPAddresses/bastion-pip"
          }
        }
      }
    ]
  }
}'

az rest --method PUT \
    --url $uri  \
    --body "$json"  \
    --output none

echo -e ".... attach application vm to pls load balancer"
# create Application VM
echo -e "$WHITE$(date +"%T")$GREEN Create Public IP and NIC $WHITE"
az network public-ip create -n $vmapp"-pip" -g $rg --version IPv4 --sku Standard -o none --only-show-errors 
az network nic create -g $rg --vnet-name plsVnet --subnet app -n $vmapp"NIC" --public-ip-address $vmapp"-pip" -o none

# default is to use your local .ssh key in folder ~/.ssh/id_rsa.pub
if [ $usessh = "true" ]; then
    echo -e "$WHITE$(date +"%T")$GREEN Creating Application VM using public key $WHITE"
    az vm create -n $vmapp -g $rg \
        --image ubuntults \
        --size $vmsize \
        --nics $vmapp"NIC" \
        --authentication-type ssh \
        --admin-username $username \
        --ssh-key-values @~/.ssh/id_rsa.pub \
        --custom-data cloud-init \
        --output none \
        --only-show-errors
else
    echo -e "$WHITE$(date +"%T")$GREEN Creating Application VM using default password $WHITE"
    az vm create -n $vmapp -g $rg \
        --image ubuntults \
        --size $vmsize \
        --nics $vmapp"NIC" \
        --admin-username $username \
        --admin-password $password \
        --custom-data cloud-init \
        --output none \
        --only-show-errors
fi

echo "$(date +"%T") ...attach app vm"
appvmnicid=$(az vm show -n $vmapp -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
appvmconfig=$(az network nic show --ids $appvmnicid --query 'ipConfigurations[0].name' -o tsv)
az network nic ip-config address-pool add --nic-name $vmapp"NIC" -g $rg --ip-config-name $appvmconfig --lb-name serviceLB --address-pool bepool1 -o none

# ======================================================
# create Private Link Endpoint

echo -e "$WHITE$(date +"%T")$GREEN Creating Private Link Endpoint ..... $WHITE"

echo -e "$WHITE$(date +"%T")$GREEN Creating Virtual Network pleVnet $WHITE"
az network vnet create \
    --resource-group $rg \
    --location $loc \
    --name pleVnet \
    --address-prefixes 11.1.0.0/16 \
    --subnet-name endpoint \
    --subnet-prefixes 11.1.0.0/24 \
    -o none

echo -e ".... creating firewall subnet"
az network vnet subnet create \
    --resource-group $rg \
    --name AzureFirewallSubnet \
    --vnet-name pleVnet \
    --address-prefixes 11.1.10.0/24 \
    -o none

echo -e ".... turn off ple network policy"
az network vnet subnet update \
    --name endpoint \
    --resource-group $rg \
    --vnet-name pleVnet \
    --disable-private-endpoint-network-policies true \
    -o none

resourceid=$(az network private-link-service show \
    --name plService \
    --resource-group $rg \
    --query id \
    --output tsv)

echo -e "$WHITE$(date +"%T")$GREEN Creating Private Endpoint $WHITE"
az network private-endpoint create \
    --connection-name pletopls \
    --name plEndpoint \
    --private-connection-resource-id $resourceid \
    --resource-group $rg \
    --subnet endpoint \
    --manual-request false \
    --vnet-name pleVnet \
    -o none

echo -e "$WHITE$(date +"%T")$GREEN Creating Firewall $WHITE"
az network firewall create \
    --name plFirewall \
    --resource-group $rg \
    --location $loc \
    -o none

az network public-ip create \
    --name plFirewall-pip \
    --resource-group $rg \
    --location $loc \
    --allocation-method static \
    --sku standard \
    -o none \
    --only-show-errors

az network firewall ip-config create \
    --firewall-name plFirewall \
    --name FW-config \
    --public-ip-address plFirewall-pip \
    --resource-group $rg \
    --vnet-name pleVnet \
    -o none

az network firewall update \
    --name plFirewall \
    --resource-group $rg \
    -o none

publicip=$(az network public-ip show --name plFirewall-pip --resource-group $rg --query ipAddress -o tsv)

echo -e "$WHITE$(date +"%T")$GREEN Creating firewall nat rule $WHITE"
az network firewall nat-rule create \
    --collection-name dnat-collection \
    --destination-addresses $publicip \
    --destination-ports 80 \
    --firewall-name plFirewall \
    --name allow-web \
    --protocols tcp \
    --resource-group $rg \
    --translated-port 80 \
    --action dnat \
    --priority 100 \
    --source-addresses '*' \
    --translated-address 11.1.0.4 \
    -o none

echo -e "$WHITE$(date +"%T")$GREEN Creating firewall network rule $WHITE"
az network firewall network-rule create \
    --collection-name net-collection \
    --destination-ports 80 \
    --firewall-name plFirewall \
    --name allow-web \
    --protocols tcp \
    --resource-group $rg \
    --action allow \
    --dest-addr $publicip \
    --priority 100 \
    --source-addresses '*' \
    -o none

echo ""
echo "Connect to http://"$publicip"/api/ip"
echo ""
