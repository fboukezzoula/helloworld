#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – LOGIQUE CORRIGÉE
#  Objectif : Calculer l'usage réel incluant les 5 IPs réservées Azure
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Configuration
OUTPUT_FILE="Azure_VNet_Usage_Corrected_$(date +%Y%m%d_%H%M%S).csv"
AZURE_RESERVED_COUNT=5

# Vérifications
command -v az >/dev/null 2>&1 || { echo "Erreur: Azure CLI non installé"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Erreur: jq non installé"; exit 1; }

# En-tête CSV
echo "VNet,ResourceGroup,Prefix,SubnetCount,UsedIPs,AvailableIPs" > "$OUTPUT_FILE"

echo "🔍 Début de l'analyse..."

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS MATHÉMATIQUES
#───────────────────────────────────────────────────────────────────────────────

# Convertir CIDR en nombre total d'IPs
cidr_to_count() {
    local mask=${1#*/}
    echo $(( 2 ** (32 - mask) ))
}

# Vérifie si subnet est dans prefix (Binaire)
subnet_in_prefix() {
    local p_ip=${1%/*} p_mask=${1#*/}
    local s_ip=${2%/*} s_mask=${2#*/}

    (( s_mask >= p_mask )) || return 1

    # Conversion IP vers Int
    local p_int s_int
    p_int=$(IFS=. read a b c d <<< "$p_ip"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )))
    s_int=$(IFS=. read a b c d <<< "$s_ip"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )))

    # Masque réseau
    local netmask=$(( 0xFFFFFFFF << (32 - p_mask) ))

    (( (p_int & netmask) == (s_int & netmask) ))
}

#───────────────────────────────────────────────────────────────────────────────
# TRAITEMENT PRINCIPAL
#───────────────────────────────────────────────────────────────────────────────

# Liste tous les VNets
while IFS=$'\t' read -r vnet_name rg vnet_id; do
    [[ -z "$vnet_name" ]] && continue
    
    echo "📊 Analyse de : $vnet_name ($rg)"

    # Récupérer les données du VNet (Prefixes + Subnets) en 1 seule requête
    vnet_json=$(az network vnet show --ids "$vnet_id" --query "{
        prefixes: addressSpace.addressPrefixes,
        subnets: subnets[].{name:name, cidr:addressPrefix}
    }" -o json 2>/dev/null)

    # Extraire les tableaux
    prefixes=$(echo "$vnet_json" | jq -r '.prefixes[]')
    subnets_json=$(echo "$vnet_json" | jq '.subnets')

    # Pour chaque Prefix du VNet
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue

        total_prefix_ips=$(cidr_to_count "$prefix")
        subnet_count=0
        total_used_in_prefix=0

        # Parcourir les subnets pour trouver ceux qui appartiennent à ce prefix
        while IFS= read -r subnet_line; do
            [[ -z "$subnet_line" ]] && continue
            
            s_name=$(echo "$subnet_line" | jq -r '.name')
            s_cidr=$(echo "$subnet_line" | jq -r '.cidr')

            # Vérifier l'appartenance mathématique
            if subnet_in_prefix "$prefix" "$s_cidr"; then
                ((subnet_count++))
                
                subnet_total=$(cidr_to_count "$s_cidr")

                # Récupérer les IPs DISPONIBLES via l'API Azure
                # L'API exclut déjà les 5 IPs réservées
                available_ips=$(az network vnet subnet list-available-ips \
                    -g "$rg" --vnet-name "$vnet_name" -n "$s_name" \
                    --query "length(@)" -o tsv 2>/dev/null || echo "0")

                # CALCUL CORRIGÉ :
                # Used = Total - Available
                # Cela inclut automatiquement les IPs réservées dans le compteur "Used"
                # car l'API Azure les a déjà retirées du "Available"
                used_in_subnet=$((subnet_total - available_ips))
                
                # Sécurité pour ne pas avoir de nombres négatifs
                (( used_in_subnet < 0 )) && used_in_subnet=0

                total_used_in_prefix=$((total_used_in_prefix + used_in_subnet))
                
                # Debug (optionnel : décommentez pour voir le détail)
                # echo "  └─ Subnet: $s_name | Total: $subnet_total | Free: $available_ips | Used: $used_in_subnet"
            fi
        done < <(echo "$subnets_json" | jq -c '.[]')

        # Calcul final des IPs disponibles dans le Prefix
        # Available = Total Prefix - Somme des IPs utilisées (Réserve + Dispositifs)
        available_in_prefix=$((total_prefix_ips - total_used_in_prefix))

        # Écriture CSV
        printf '%s,%s,%s,%s,%s,%s\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" "$total_used_in_prefix" "$available_in_prefix" >> "$OUTPUT_FILE"

    done <<< "$prefixes"

done < <(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv)

echo ""
echo "✅ Terminé !"
echo "📄 Fichier : $OUTPUT_FILE"
