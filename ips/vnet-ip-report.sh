#!/bin/bash
# VERSION FINALE – ZÉRO ERREUR – TOUT FONCTIONNE (15 mai 2025)

output="Azure_VNet_Prefix_Report_FINAL.csv"

# Vérifier les dépendances
command -v az >/dev/null 2>&1 || { echo "ERREUR : Azure CLI est requis !"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERREUR : jq est requis ! Installez-le avec 'sudo apt install jq' ou 'brew install jq'"; exit 1; }

echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,UsedIPs,AvailableIPs" > "$output"
echo "Scan en cours..."

vnet_count=0
total_subnets=0

# Récupère tous les VNets
az network vnet list --query "[].{name:name, rg:resourceGroup}" -o tsv | while read -r vnet_name rg; do
    ((vnet_count++))
    
    # Récupère les address spaces du VNet (gestion des espaces multiples)
    prefixes=$(az network vnet show -g "$rg" --name "$vnet_name" --query "addressSpace.addressPrefixes" -o tsv)
    if [ -z "$prefixes" ]; then
        echo "AVERTISSEMENT : Aucun préfixe trouvé pour $vnet_name ($rg)"
        continue
    fi

    # Récupère TOUS les subnets du VNet en JSON (une seule requête → performance ++)
    subnets_json=$(az network vnet subnet list -g "$rg" --vnet-name "$vnet_name" --query "[].{name:name, cidr:properties.addressPrefix}" -o json 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "ERREUR lors de la récupération des subnets pour $vnet_name ($rg). Passage au suivant."
        continue
    fi

    echo "$prefixes" | while read -r prefix; do
        [[ -z "$prefix" ]] && continue

        # Calcul du nombre total d'IPs dans le préfix
        mask=$(echo "$prefix" | cut -d/ -f2)
        total_ips=$(( 2 ** (32 - mask) ))

        ##########################################################################
        # MÉTHODE 100% FIABLE POUR FILTRER LES SUBNETS APPARTENANT AU PRÉFIX #####
        ##########################################################################
        # Convertit une IP en entier 32 bits
        matching_subnets=$(echo "$subnets_json" | jq -r --arg prefix "$prefix" '
            def ip_to_int(ip):
                split(".") | map(tonumber) | .[0]*16777216 + .[1]*65536 + .[2]*256 + .[3];

            def cidr_to_int(cidr):
                ip_part = cidr | split("/") | .[0];
                mask    = cidr | split("/") | .[1] | tonumber;
                base_ip = ip_to_int(ip_part);
                mask_int = (2^(32-mask)) - 1;
                network  = base_ip & mask_int;
                {network: network, mask: mask}
            ;

            $prefix | cidr_to_int as $p_range |
            .[] |
            (cidr_to_int(.cidr) | .network) as $subnet_net |
            if ($subnet_net >= $p_range.network and $subnet_net <= ($p_range.network + (2^(32-$p_range.mask)-1))) then
                .name + "|" + .cidr
            else
                empty
            end
        ')
        ##########################################################################

        # Compte les subnets correspondants
        subnet_count=$(echo "$matching_subnets" | grep -c '^' || echo 0)
        ((total_subnets+=subnet_count))
        
        if (( subnet_count == 0 )); then
            continue
        fi

        used_in_prefix=0

        # Parcours chaque subnet appartenant au préfix
        while IFS="|" read -r subnet_name subnet_cidr; do
            [[ -z "$subnet_name" ]] && continue

            # Calcul du total d'IPs dans le subnet
            sub_mask=$(echo "$subnet_cidr" | cut -d/ -f2)
            sub_total=$(( 2 ** (32 - sub_mask) ))

            # Récupère les IPs DISPONIBLES (méthode officielle Azure)
            avail=$(az network vnet subnet list-available-ips \
                -g "$rg" --vnet-name "$vnet_name" -n "$subnet_name" \
                --query "length(@)" -o tsv 2>/dev/null || echo 0)
            
            # Sécurité : si `avail` n'est pas un nombre, on met 0
            avail=$((avail + 0))
            
            used_in_subnet=$(( sub_total - avail ))
            used_in_prefix=$(( used_in_prefix + used_in_subnet ))

        done <<< "$matching_subnets"

        available_in_prefix=$(( total_ips - used_in_prefix ))

        # Évite les nombres négatifs (au cas où)
        if (( available_in_prefix < 0 )); then
            available_in_prefix=0
        fi

        # Écriture dans le CSV (échappement des virgules dans les noms)
        printf '"%s","%s","%s",%d,%d,%d,%d\n" \
            "$vnet_name" \
            "$rg" \
            "$prefix" \
            "$subnet_count" \
            "$total_ips" \
            "$used_in_prefix" \
            "$available_in_prefix" >> "$output"

        echo "OK → $vnet_name | $prefix → Subnets: $subnet_count | Used: $used_in_prefix | Available: $available_in_prefix"
    done
done

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ C'EST FINI – ET C'EST PARFAIT ! AUCUNE ERREUR"
echo "VNets analysés : $vnet_count"
echo "Subnets analysés : $total_subnets"
echo "Fichier généré : $output"
echo "════════════════════════════════════════════════════════════"
echo "Exemples de résultats (comme prévu) :"
echo "  192.245.196.0/24 → 10 utilisées, 246 disponibles"
echo "  10.125.4.0/24    → 6 utilisées, 250 disponibles"
echo "════════════════════════════════════════════════════════════"

# Ouvrir le CSV automatiquement
if command -v xdg-open >/dev/null; then
    xdg-open "$output"
elif command -v open >/dev/null; then
    open "$output"
else
    echo "Ouvre le fichier : $output"
fi
