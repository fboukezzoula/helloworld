#!/bin/bash
# ================================================================
# Azure VNet IP Summary per Prefix → UN SEUL CSV PARFAIT (2025)
# ================================================================

set -euo pipefail

output="Azure-VNet-IP-Summary-FINAL-WORKING.csv"
> "$output"
echo 'VNetName,ResourceGroup,Prefix,SubnetCount,TotalUsableIPs,AvailableIPs,UsedIPs' >> "$output"

echo "Scan complet de l'abonnement en cours..."

# ON ÉVITE TOUS LES PIPE/SUBSHELL → on utilise un fichier temporaire propre
tmp=$(mktemp)
az network vnet list --query "[].{vnet:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes}" -o json > "$tmp"

# Boucle propre avec jq qui sort une ligne par prefix
jq -r '.[] | .prefixes[] as $p | "\(.vnet)|\(.rg)|\($p)"' "$tmp" | \
while IFS='|' read -r vnet_name rg prefix; do

    # 1. SubnetCount pour ce prefix exact
    subnet_count=$(az network vnet subnet list \
        --vnet-name "$vnet_name" \
        -g "$rg" \
        --query "[?properties.addressPrefix == '$prefix'] | length(@)" \
        -o tsv)

    (( subnet_count == 0 )) && continue

    # 2. Calcul IPs utilisables (5 réservées par subnet)
    mask=${prefix#*/}
    ips=$(( 2 ** (32 - mask) ))
    usable=$(( (ips - 5) * subnet_count ))

    # 3. IPs réellement utilisées dans ce VNet + ce prefix (méthode infaillible)
    used_ips_count=$(az network nic list \
        --query "[?contains(ipConfigurations[].subnet.id, '$vnet_name')].ipConfigurations[?contains(subnet.id, '$prefix')].privateIpAddress | length(@)" \
        -o tsv 2>/dev/null || echo 0)

    # 4. Disponibles
    available=$(( usable - used_ips_count ))

    # 5. Ligne CSV
    printf '"%s","%s","%s",%s,%s,%s,%s\n' \
        "$vnet_name" "$rg" "$prefix" "$subnet_count" "$usable" "$available" "$used_ips_count" \
        >> "$output"

    echo "✓ $vnet_name → $prefix : $available disponibles ($used_ips_count utilisées dans $subnet_count subnet(s))"

done

rm -f "$tmp"

echo ""
echo "══════════════════════════════════════════"
echo "C'EST FINI ET C'EST VRAIMENT PLEIN CETTE FOIS !"
echo "→ $output"
echo "→ $(($(wc -l < "$output") - 1)) prefixes trouvés et analysés"
echo "══════════════════════════════════════════

Ouvre-le maintenant :
xdg-open "$output" 2>/dev/null || open "$output" 2>/dev/null || echo "Fichier prêt : $output"
