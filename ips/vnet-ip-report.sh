#!/bin/bash
# VERSION QUI MARCHE VRAIMENT — 11 avril 2025
output="Azure-VNet-IP-Summary-OK.csv"
echo 'VNetName,ResourceGroup,Prefix,SubnetCount,TotalUsableIPs,AvailableIPs,UsedIPs' > "$output"

# 1. On récupère TOUS les subnets avec leur VNet + RG + Prefix en UNE SEULE REQUÊTE
az network vnet subnet list \
  --query "[].{ \
    vnet: virtualNetwork.id | split('/')[-1], \
    rg: resourceGroup, \
    prefix: properties.addressPrefix \
  }" -o json | jq -r '.[] | "\(.vnet)|\(.rg)|\(.prefix)"' | sort -u | \
  
while IFS='|' read -r vnet_name rg prefix; do

    # Compte le nombre de subnets pour ce prefix EXACT
    subnet_count=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" --query "[?properties.addressPrefix == '$prefix'] | length(@)" -o tsv)

    # Calcul IPs utilisables (5 réservées par subnet)
    mask=${prefix#*/}
    total_ips=$(( 2 ** (32 - mask) ))
    usable=$(( (total_ips - 5) * subnet_count ))

    # IPs réellement utilisées dans ce VNet (toutes les NIC du VNet)
    used_ips_count=$(az network nic list -g "$rg" --query "[?virtualMachine != null && contains(ipConfigurations[].subnet.id, '$vnet_name')].ipConfigurations[].privateIpAddress | length(@)" -o tsv 2>/dev/null || echo 0)

    # Disponibles
    available=$(( usable - used_ips_count ))

    # Écriture CSV
    printf '"%s","%s","%s",%s,%s,%s,%s\n' "$vnet_name" "$rg" "$prefix" "$subnet_count" "$usable" "$available" "$used_ips_count" >> "$output"

    echo "✓ $vnet_name → $prefix → $available disponibles ($used_ips_count utilisées sur $subnet_count subnet(s))"

done

echo ""
echo "════════════════════════════════"
echo "C'EST FINI ET C'EST PLEIN !!"
echo "Fichier : $output"
echo "Lignes : $(wc -l < "$output") (entête incluse)"
echo "════════════════════════════════"
xdg-open "$output" || open "$output" || echo "Ouvre $output"
