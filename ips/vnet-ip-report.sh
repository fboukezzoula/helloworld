#!/bin/bash

output="Azure_VNet_Prefix_Report.csv"
# En-tête avec l'ordre demandé
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,UsedIPs,AvailableIPs" > "$output"

echo "Analyse des réseaux en cours..."

# 1. Récupérer les VNets
vnets_json=$(az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes}" -o json)

echo "$vnets_json" | jq -c '.[]' | while read -r vnet; do
    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')
    
    # 2. Récupérer les subnets du VNet
    subnets_json=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" -o json)

    # 3. Boucler sur chaque Address Space (Prefix)
    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do
        
        # Taille totale du Prefix (ex: /24 = 256)
        prefix_mask=$(echo "$prefix" | cut -d/ -f2)
        total_prefix_ips=$(( 2 ** (32 - prefix_mask) ))

        # Filtrer les subnets appartenant à ce prefix
        # On utilise une comparaison sur les 2 ou 3 premiers octets pour éviter les erreurs JQ
        prefix_part=$(echo "$prefix" | cut -d. -f1-2)
        matching_subnets=$(echo "$subnets_json" | jq -c ".[] | select(.addressPrefix != null) | select(.addressPrefix | startswith(\"$prefix_part\"))")
        
        subnet_count=$(echo "$matching_subnets" | jq -s 'length')

        if [ "$subnet_count" -gt 0 ]; then
            sum_used_in_subnets=0

            while read -r subnet; do
                [ -z "$subnet" ] && continue
                sub_name=$(echo "$subnet" | jq -r '.name')
                sub_cidr=$(echo "$subnet" | jq -r '.addressPrefix')
                
                # Taille du subnet (ex: /25 = 128)
                sub_mask=$(echo "$sub_cidr" | cut -d/ -f2)
                sub_total_ips=$(( 2 ** (32 - sub_mask) ))

                # IPs réellement disponibles (via API Azure)
                sub_avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$sub_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
                
                # IPs utilisées dans ce subnet (Réserves Azure + Ressources)
                sub_used=$(( sub_total_ips - sub_avail ))
                sum_used_in_subnets=$(( sum_used_in_subnets + sub_used ))

            done <<< "$matching_subnets"

            # Logique finale demandée :
            # UsedIPs = ce qui est consommé dans les subnets
            # AvailableIPs = Tout le reste du bloc prefix
            final_used=$sum_used_in_subnets
            final_available=$(( total_prefix_ips - final_used ))

            # Ecriture CSV
            echo "\"$vnet_name\",\"$rg\",\"$prefix\",$subnet_count,$total_prefix_ips,$final_used,$final_available" >> "$output"
            echo "✓ $vnet_name [$prefix] : $final_used utilisées, $final_available disponibles."
        fi
    done
done

echo "------------------------------------------------"
echo "Rapport généré avec succès : $output"
