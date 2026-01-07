#!/bin/bash

# Fichier de sortie
output="Azure_VNet_Prefix_Report.csv"
echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalUsableIPs,AvailableIPs,UsedIPs" > "$output"

echo "Début du scan (récupération des VNets...)"

# 1. Récupérer la liste des VNets
vnets_json=$(az network vnet list --query "[].{name:name, rg:resourceGroup, prefixes:addressSpace.addressPrefixes}" -o json)

# 2. Boucler sur chaque VNet
echo "$vnets_json" | jq -c '.[]' | while read -r vnet; do
    vnet_name=$(echo "$vnet" | jq -r '.name')
    rg=$(echo "$vnet" | jq -r '.rg')
    
    echo "Analyse du VNet: $vnet_name..."

    # 3. Récupérer TOUS les subnets de CE VNet (Correction de l'erreur précédente)
    subnets_json=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" -o json)

    # 4. Pour chaque préfixe (Address Space) déclaré dans le VNet
    echo "$vnet" | jq -r '.prefixes[]' | while read -r prefix; do
        
        # On filtre les subnets qui appartiennent à ce préfixe
        # On utilise une logique simple : le subnet_prefix doit commencer par le début du vnet_prefix (ex: 10.125.4.x)
        prefix_base=$(echo "$prefix" | cut -d. -f1-2) # On prend les 2 premiers octets pour le groupage
        
        matching_subnets=$(echo "$subnets_json" | jq -c ".[] | select(.addressPrefix | startswith(\"$prefix_base\"))")
        
        subnet_count=$(echo "$matching_subnets" | jq -s 'length')

        if [ "$subnet_count" -gt 0 ]; then
            total_usable=0
            total_available=0

            # Calcul pour chaque subnet trouvé dans ce préfixe
            while read -r subnet; do
                [ -z "$subnet" ] && continue
                
                sub_name=$(echo "$subnet" | jq -r '.name')
                sub_cidr=$(echo "$subnet" | jq -r '.addressPrefix')
                
                # Nombre d'IPs total dans le CIDR (ex: /24 = 256)
                mask=$(echo "$sub_cidr" | cut -d/ -f2)
                total_ips_in_cidr=$(( 2 ** (32 - mask) ))
                
                # IPs utilisables chez Azure (Total - 5)
                usable_in_subnet=$(( total_ips_in_cidr - 5 ))
                
                # IPs disponibles (Appel API pour avoir le chiffre exact du portail)
                avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$sub_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
                
                total_usable=$(( total_usable + usable_in_subnet ))
                total_available=$(( total_available + avail ))

            done <<< "$matching_subnets"

            used_ips=$(( total_usable - total_available ))

            # Ecriture dans le CSV
            echo "$vnet_name,$rg,$prefix,$subnet_count,$total_usable,$total_available,$used_ips" >> "$output"
            echo "   -> Prefix $prefix : $subnet_count subnets trouvés."
        fi
    done
done

echo "------------------------------------------------"
echo "TERMINÉ : Le fichier $output a été généré."
echo "------------------------------------------------"
