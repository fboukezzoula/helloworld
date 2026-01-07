#!/bin/bash
# ================================================================
# Azure - IP Summary per VNet & per Address Prefix (exactly what you asked)
# Output: one CSV file per VNet → perfect for Excel / PowerBI
# ================================================================

az login >/dev/null

mkdir -p VNet-IP-Summary-Per-Prefix
echo "Processing all VNets..."

az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes[]}" -o json \
| jq -c '.[]' | while read -r vnet; do

    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')
    output="VNet-IP-Summary-Per-Prefix/${vnet_name}.csv"

    echo "VNetName,Prefix,TotalUsableIPs,AvailableIPs,UsedIPs,SubnetCount" > "$output"

    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do

        # Count how many subnets use this exact prefix
        subnet_count=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" --query "length([?properties.addressPrefix=='$prefix'])" -o tsv)

        # Total usable IPs in this prefix (Azure reserves 5 per subnet, but we calculate per prefix)
        cidr=$(echo "$prefix" | cut -d/ -f2)
        total_ips=$(( 2 ** (32 - cidr) ))
        usable_per_subnet=$(( total_ips - 5 ))
        total_usable=$(( usable_per_subnet * subnet_count ))

        # Real used IPs in this prefix (across all subnets that belong to it)
        used_ips_count=$(az network nic list --query "length([?ipConfigurations[0].subnet.id != null && contains(ipConfigurations[0].subnet.id, '$prefix')].ipConfigurations[].privateIpAddress)" -o tsv)

        available_ips=$(( total_usable - used_ips_count ))

        printf '%s,"%s",%s,%s,%s,%s\n' \
            "$vnet_name" "$prefix" "$total_usable" "$available_ips" "$used_ips_count" "$subnet_count" \
            >> "$output"
    done

    echo "Saved → $output"
done

echo ""
echo "TOUS LES FICHIERS SONT PRÊTS DANS LE DOSSIER : ./VNet-IP-Summary-Per-Prefix/"
echo "Chaque VNet a son propre CSV, exactement comme tu le voulais !"
