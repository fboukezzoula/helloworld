#!/bin/bash

output="Azure_VNet_Prefix_Report.csv"
# En-têtes : TotalPrefixIPs (ex: 256 pour un /24), UsedIPs (inclut les 5 réserves Azure + vos VMs)
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,AvailableIPs,UsedIPs" > "$output"

echo "Analyse des réseaux en cours..."

# 1. Récupérer les VNets
vnets_json=$(az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes}" -o json)

echo "$vnets_json" | jq -c '.[]' | while read -r vnet; do
    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')
    
    # 2. Récupérer tous les subnets du VNet une seule fois pour économiser du temps
    subnets_json=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" -o json)

    # 3. Boucler sur chaque Address Space (Prefix) du VNet
    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do
        
        # Calcul du nombre total d'IP théoriques dans le préfixe (ex: /24 = 256)
        prefix_mask=$(echo "$prefix" | cut -d/ -f2)
        total_prefix_ips=$(( 2 ** (32 - prefix_mask) ))

        # Filtrer les subnets appartenant à ce prefix
        # On vérifie si le prefix du subnet est contenu dans le prefix du VNet
        # Correction bug JQ : on s'assure que addressPrefix n'est pas null
        matching_subnets=$(echo "$subnets_json" | jq -c ".[] | select(.addressPrefix != null) | select(.addressPrefix | startswith(\"${prefix%.*}\"))")
        
        subnet_count=$(echo "$matching_subnets" | jq -s 'length')

        if [ "$subnet_count" -gt 0 ]; then
            sum_available=0

            # 4. Calculer les IPs disponibles via l'API (exactement comme le portail)
            while read -r subnet; do
                [ -z "$subnet" ] && continue
                sub_name=$(echo "$subnet" | jq -r '.name')
                
                # Commande la plus fiable pour correspondre au portail
                avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$sub_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
                sum_available=$(( sum_available + avail ))
            done <<< "$matching_subnets"

            # 5. Logique de calcul demandée :
            # Used = Total du bloc - Ce qui est réellement disponible
            # (Cela inclut donc les 5 IPs réservées par subnet dans le "Used")
            used_ips=$(( total_prefix_ips - sum_available ))

            # Ecriture CSV
            echo "\"$vnet_name\",\"$rg\",\"$prefix\",$subnet_count,$total_prefix_ips,$sum_available,$used_ips" >> "$output"
            echo "✓ $vnet_name [$prefix] : $sum_available disponibles, $used_ips utilisées (incluant réserves Azure)."
        fi
    done
done

echo "------------------------------------------------"
echo "Rapport généré : $output"
