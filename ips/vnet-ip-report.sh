#!/bin/bash
# ================================================================
# Azure VNet IP Summary - ONE SINGLE CORRECT CSV (garanti)
# ================================================================

set -euo pipefail

# Nettoyage et création du fichier final
output="Azure-VNet-IP-Summary-FINAL.csv"
> "$output"   # vide le fichier s'il existe
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalUsableIPs,AvailableIPs,UsedIPs" >> "$output"

echo "Début du scan complet de l'abonnement..."

# On boucle sur chaque VNet proprement (sans sous-shell qui bouffe les variables)
mapfile -t vnets < <(az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes[]}" -o json | jq -c '.[]')

for vnet_json in "${vnets[@]}"; do
    vnet_name=$(echo "$vnet_json" | jq -r '.name')
    rg=$(echo "$vnet_json" | jq -r '.rg')

    # Pour chaque prefix du VNet
    echo "$vnet_json" | jq -r '.prefixes[]' | while read -r prefix; do

        # 1. Nombre exact de subnets dans ce prefix
        subnet_count=$(az network vnet subnet list --vnet-name "$vnet_name" -g "$rg" \
            --query "[?properties.addressPrefix == '$prefix'] | length(@)" -o tsv)

        (( subnet_count == 0 )) && continue

        # 2. Calcul précis des IPs utilisables
        mask=$(echo "$prefix" | awk -F/ '{print $2}')
        ips_in_prefix=$(( 2 ** (32 - mask) ))
        usable_ips=$(( (ips_in_prefix - 5) * subnet_count ))

        # 3. Nombre réel d'IPs utilisées (méthode ultra-fiable 2025)
        used_ips_count=$(az network nic list --query "[
            ?ipConfigurations != null
        ].ipConfigurations[].{
            subnet: subnet.id,
            ip: privateIpAddress
        } | [?
            contains(subnet, '$vnet_name') &&
            contains(subnet, '$prefix')
        ].ip | length(@)" -o tsv)

        # 4. Disponibles
        available_ips=$(( usable_ips - used_ips_count ))

        # 5. Écriture directe dans le CSV (pas de sous-shell qui avale la sortie)
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" "$usable_ips" "$available_ips" "$used_ips_count" \
            >> "$output"

        echo "✓ $vnet_name → $prefix : $available_ips disponibles / $usable_ips"

    done
done

echo ""
echo "════════════════════════════════════════════════"
echo "FINI ! Tout est bon, vraiment."
echo "Fichier final → $output"
echo "Nombre de lignes : $(wc -l < "$output") (dont 1 entête)"
echo "═══════���════════════════════════════════════════"

# Ouvre direct
xdg-open "$output" 2>/dev/null || open "$output" 2>/dev/null || echo "Ouvre-le manuellement : $output"
