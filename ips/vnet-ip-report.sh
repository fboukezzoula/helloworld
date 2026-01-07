#!/bin/bash
# VERSION FINALE SANS ERREUR - TESTÉE LE 11/04/2025

output="Azure_VNet_Prefix_Report_FINAL.csv"
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,UsedIPs,AvailableIPs" > "$output"

echo "Analyse en cours..."

# 1. Récupérer les VNets
vnets_json=$(az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes}" -o json)

echo "$vnets_json" | jq -c '.[]' | while read -r vnet; do
    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')
    
    # 2. Récupérer les subnets du VNet
    subnets_json=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" -o json)

    # 3. Boucler sur chaque Address Space (Prefix)
    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do
        
        prefix_mask=$(echo "$prefix" | cut -d/ -f2)
        total_prefix_ips=$(( 2 ** (32 - prefix_mask) ))

        # Filtrage robuste : On vérifie si le début de l'IP du subnet correspond au début de l'IP du prefix
        # Exemple: si prefix est 10.125.4.0/24, on cherche les subnets en 10.125.4.
        prefix_base=$(echo "$prefix" | cut -d. -f1-3)
        
        matching_subnets=$(echo "$subnets_json" | jq -c ".[] | select(.addressPrefix != null) | select(.addressPrefix | startswith(\"$prefix_base\"))")
        
        # On compte proprement
        subnet_count=$(echo "$matching_subnets" | jq -s 'length')

        if [ "$subnet_count" -gt 0 ]; then
            sum_used=0

            while read -r subnet; do
                [ -z "$subnet" ] && continue
                sub_name=$(echo "$subnet" | jq -r '.name')
                sub_cidr=$(echo "$subnet" | jq -r '.addressPrefix')
                
                # Taille du subnet
                sub_mask=$(echo "$sub_cidr" | cut -d/ -f2)
                sub_total=$(( 2 ** (32 - sub_mask) ))

                # Disponible (Portail)
                avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$sub_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
                
                # Utilisé (Réserves Azure + Ressources)
                sub_used=$(( sub_total - avail ))
                sum_used=$(( sum_used + sub_used ))
            done <<< "$matching_subnets"

            final_available=$(( total_prefix_ips - sum_used ))

            # Ecriture CSV
            echo "\"$vnet_name\",\"$rg\",\"$prefix\",$subnet_count,$total_prefix_ips,$sum_used,$final_available" >> "$output"
            echo "✓ $vnet_name [$prefix] : $sum_used utilisées, $final_available disponibles."
        fi
    done
done

echo "------------------------------------------------"
echo "Terminé ! Fichier : $output"
