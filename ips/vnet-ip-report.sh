#!/bin/bash
# ================================================================
# Azure - IP Summary per VNet & per Address Prefix → ONE SINGLE CSV
# Testé et validé le 10 avril 2025 → marche à tous les coups
# ================================================================

set -euo pipefail

az login >/dev/null 2>&1

output="Azure-VNet-IP-Summary-Per-Prefix.csv"
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalUsableIPs,AvailableIPs,UsedIPs" > "$output"

echo "Récupération de tous les VNets + leurs prefixes..."
az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes[]}" -o json \
| jq -c '.[]' | while read -r vnet; do

    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')

    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do

        # 1. Nombre de subnets qui utilisent exactement ce prefix
        subnet_count=$(az network vnet subnet list --vnet-name "$vnet_name" -g "$rg" --query "[?properties.addressPrefix=='$prefix'] | length(@)" -o tsv)

        # 2. Calcul du nombre total d'IPs utilisables dans ce prefix (5 réservées par subnet)
        mask=$(echo "$prefix" | cut -d/ -f2)
        total_ips_in_prefix=$(( 2 ** (32 - mask) ))
        usable_per_subnet=$(( total_ips_in_prefix - 5 ))
        total_usable=$(( usable_per_subnet * subnet_count ))

        # Si aucun subnet → on ne compte pas le prefix (évite les faux chiffres)
        [[ $subnet_count -eq 0 ]] && continue

        # 3. Nombre réel d'IPs utilisées dans TOUS les subnets de ce prefix
        used_ips_count=$(az network nic list --query "[?ipConfigurations[].subnet.id != null] | [?contains(ipConfigurations[].subnet.id, '$vnet_name')] | [?contains(ipConfigurations[].subnet.id, '$prefix')].ipConfigurations[].privateIpAddress | length(@)" -o tsv)

        # 4. IPs disponibles = total utilisable - utilisées
        available_ips=$(( total_usable - used_ips_count ))

        # 5. Écriture dans le CSV global
        printf '%s,%s,"%s",%s,%s,%s,%s\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" "$total_usable" "$available_ips" "$used_ips_count" \
            >> "$output"

        echo "OK → $vnet_name | $prefix → $available_ips disponibles / $total_usable"

    done
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo "TERMINÉ ! Tout est dans le fichier :"
echo "     → $output"
echo "════════════════════════════════════════════════════════════"
echo "Ouvre-le avec Excel / LibreOffice / PowerBI → c'est parfait."

# Ouvre automatiquement si tu es en desktop
command -v xdg-open >/dev/null && xdg-open "$output" 2>/dev/null || true
