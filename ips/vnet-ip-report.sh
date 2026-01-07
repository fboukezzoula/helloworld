#!/bin/bash
# ================================================================
# Azure VNet / Subnet IP Usage Report (Linux - az cli version)
# - Lists every used IP and every *actually available* IP per subnet
# - Accurate (respects Azure's 5 reserved IPs)
# - Works on any Linux distro with az cli + jq installed
# ================================================================

# Login (opens browser or device code flow)
az login >/dev/null

# Optional: set specific subscription if you have multiple
# az account set --subscription "My Subscription Name or ID"

output="VNetIPReport.csv"
echo "VNetName,VNetAddressSpace,SubnetName,SubnetAddressSpace,UsedIPs,FreeIPs" > "$output"

echo "Fetching all NIC → private IP mappings (subscription-wide, one call)..."
# Build a JSON map:  "subnet-full-id" : ["10.0.1.4","10.0.1.5",...]
used_map=$(az network nic list --query \
  "[].ipConfigurations[].{ip:privateIPAddress, subnet:subnet.id}" -o json \
  | jq 'reduce .[] as $i ({}; 
        if ($i.subnet and $i.ip) then .[$i.subnet] += [$i.ip] else . end)')

echo "Processing VNets and subnets..."
az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes[], subnets:subnets[]}" -o json \
| jq -c '.[]' | while read -r vnet; do
      
      vnet_name=$(echo "$vnet" | jq -r '.name')
      rg=$(echo "$vnet" | jq -r '.rg')
      address_space=$(echo "$vnet" | jq -r '.prefixes | join(", ")')
      
      echo "$vnet" | jq -c '.subnets[]' | while read -r subnet; do
          subnet_name=$(echo "$subnet" | jq -r '.name')
          subnet_prefix=$(echo "$subnet" | jq -r '.properties.addressPrefix')
          subnet_id=$(echo "$subnet" | jq -r '.id')

          # ===== Used IPs =====
          used_ips=$(echo "$used_map" | jq -r ".[\"$subnet_id\"] // [] | sort | join(\", \")")
          [ -z "$used_ips" ] && used_ips="None"

          # ===== Actually available IPs (Microsoft official command) =====
          free_ips=$(az network vnet subnet list-available-ips \
                       -g "$rg" --vnet-name "$vnet_name" --name "$subnet_name" \
                       -o json 2>/dev/null \
                     | jq -r 'sort | join(", ")')
          [ -z "$free_ips" ] || [ "$free_ips" = "null" ] && free_ips="None or command not supported on this subnet"

          # ===== Write CSV line =====
          printf '%s,"%s","%s","%s","%s","%s"\n' \
                 "$vnet_name" "$address_space" "$subnet_name" "$subnet_prefix" "$used_ips" "$free_ips" \
                 >> "$output"
      done
done




echo "Done! Report saved to ./$output"
echo "   (Open with Excel/LibreOffice - it handles the quoting correctly)"
