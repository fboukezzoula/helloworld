#!/bin/bash
# VERSION PRODUCTION – CORRECTE ET RAPIDE

set -e  # Arrête immédiatement en cas d'erreur

# Configuration
output="Azure_VNet_Prefix_Report_PROD.csv"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT  # Nettoie à la fin

# Vérifications préliminaires
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI non installé"; exit 1; }
az account show >/dev/null 2>&1 || { echo "❌ Non connecté à Azure"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq non installé"; exit 1; }

echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,UsedIPs,AvailableIPs" > "$output"
echo "🔍 Scan en cours..."

# === FONCTIONS MATHS IP CORRECTES ===
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

network_contains() {
    local prefix=$1
    local subnet=$2
    
    local prefix_ip=$(cut -d/ -f1 <<< "$prefix")
    local prefix_mask=$(cut -d/ -f2 <<< "$prefix")
    local subnet_ip=$(cut -d/ -f1 <<< "$subnet")
    local subnet_mask=$(cut -d/ -f2 <<< "$subnet")
    
    # Le subnet doit avoir un masque PLUS GRAND ou égal
    (( subnet_mask >= prefix_mask )) || return 1
    
    local prefix_int=$(ip_to_int "$prefix_ip")
    local subnet_int=$(ip_to_int "$subnet_ip")
    
    local mask_int=$((0xFFFFFFFF << (32 - prefix_mask)))
    
    # Vérifie que le subnet est DANS le prefix
    (( (subnet_int & mask_int) == (prefix_int & mask_int) ))
}

# === LOGIQUE PRINCIPALE OPTIMISÉE ===
az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv | while IFS=$'\t' read -r vnet_name rg vnet_id; do
    
    # Récupère TOUT en UNE SEULE requête
    mapfile -t prefixes < <(az network vnet show --ids "$vnet_id" --query "addressSpace.addressPrefixes[]" -o tsv)
    subnets_json=$(az network vnet show --ids "$vnet_id" --query "subnets[].{name:name, cidr:addressPrefix}" -o json)
    
    for prefix in "${prefixes[@]}"; do
        [[ -z "$prefix" ]] && continue
        
        # Parse prefix
        prefix_mask=$(cut -d/ -f2 <<< "$prefix")
        total_ips=$(( 2 ** (32 - prefix_mask) ))
        
        # Filtre les subnets avec la logique CORRECTE
        matching_subnets=$(echo "$subnets_json" | jq -r --arg p "$prefix" '
            .[] | select(
                ($p | split("/")[0] | split(".") | map(tonumber)) as $p_ip |
                ($p | split("/")[1] | tonumber) as $p_mask |
                (.cidr | split("/")[0] | split(".") | map(tonumber)) as $s_ip |
                (.cidr | split("/")[1] | tonumber) as $s_mask |
                
                # Vérifie le masque et le réseau
                $s_mask >= $p_mask and
                ($s_ip[0] << 24 | $s_ip[1] << 16 | $s_ip[2] << 8 | $s_ip[3]) as $s_int |
                ($p_ip[0] << 24 | $p_ip[1] << 16 | $p_ip[2] << 8 | $p_ip[3]) as $p_int |
                ((0xFFFFFFFF << (32 - $p_mask)) & $s_int) == ((0xFFFFFFFF << (32 - $p_mask)) & $p_int)
            ) | .name
        ')
        
        subnet_count=$(wc -l <<< "$matching_subnets")
        (( subnet_count == 0 )) && continue
        
        # === CALCUL DES IPs UTILISÉES (CORRECT) ===
        used_in_prefix=0
        
        while IFS= read -r subnet_name; do
            [[ -z "$subnet_name" ]] && continue
            
            subnet_cidr=$(echo "$subnets_json" | jq -r --arg n "$subnet_name" '.[] | select(.name==$n) | .cidr')
            subnet_mask=$(cut -d/ -f2 <<< "$subnet_cidr")
            
            # Récupère les IPs disponibles (Azure exclut les réservées)
            avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$subnet_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
            
            sub_total=$(( 2 ** (32 - subnet_mask) ))
            
            # Les 5 IPs réservées par Azure sont DÉJÀ exclues de 'avail'
            used_in_subnet=$(( sub_total - avail ))
            used_in_prefix=$(( used_in_prefix + used_in_subnet ))
            
        done <<< "$matching_subnets"
        
        available_in_prefix=$(( total_ips - used_in_prefix ))
        
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" "$total_ips" "$used_in_prefix" "$available_in_prefix" >> "$output"
        
        echo "✅ $vnet_name | $prefix → $subnet_count subnets → Used: $used_in_prefix | Available: $available_in_prefix"
    done
done

echo ""
echo "════════════════════════════════════"
echo "✨ ANALYSE TERMINÉE"
echo "📄 Fichier généré : $output"
echo "════════════════════════════════════"

# Ouvre le fichier
if command -v xdg-open &>/dev/null; then
    xdg-open "$output"
elif command -v open &>/dev/null; then
    open "$output"
else
    echo "Ouvre manuellement : $output"
fi
