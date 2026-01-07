#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION ARCHITECTURE "BOUCLE FOR"
#  Correctif : Remplace les 'while read' par des 'for' pour éviter les conflits stdin
#═══════════════════════════════════════════════════════════════════════════════

set -u

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
OUTPUT_FILE="Azure_VNet_Usage_Final_$(date +%Y%m%d_%H%M%S).csv"
AZURE_RESERVED_COUNT=5
MAX_RETRIES=3

# ── PYTHON HELPERS (Les mêmes qui fonctionnaient) ─────────────────────────────
cidr_to_count() {
    python3 -c "import sys, ipaddress; print(ipaddress.ip_network(sys.argv[1].strip(), strict=False).num_addresses)" "$1" 2>/dev/null || echo 0
}

subnet_in_prefix() {
    python3 -c "
import sys, ipaddress
try:
    p = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    s = ipaddress.ip_network(sys.argv[2].strip(), strict=False)
    sys.exit(0 if s.subnet_of(p) else 1)
except: sys.exit(1)
" "$1" "$2"
}

# ── DEPENDENCIES ──────────────────────────────────────────────────────────────
command -v az >/dev/null || { echo "Azure CLI manquant"; exit 1; }
command -v jq >/dev/null || { echo "jq manquant"; exit 1; }
command -v python3 >/dev/null || { echo "python3 manquant"; exit 1; }

# ── MAIN ──────────────────────────────────────────────────────────────────────
echo "VNet,ResourceGroup,Prefix,SubnetCount,ReservedAzureIPs,UsedIPs,AvailableIPs,UsagePercent" > "$OUTPUT_FILE"

echo "🔍 Démarrage..."

# 1. On charge TOUS les VNets d'un coup dans une variable multilingue
# On utilise un séparateur personnalisé pour être sûr
raw_vnets=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv)

if [[ -z "$raw_vnets" ]]; then
    echo "❌ Aucun VNet trouvé."
    exit 1
fi

# On change le séparateur interne (IFS) pour lire ligne par ligne uniquement
IFS=$'\n'
for line in $raw_vnets; do
    # On remet l'IFS par défaut temporairement pour découper la ligne par tabulations
    IFS=$'\t' read -r vnet_name rg vnet_id <<< "$line"
    IFS=$'\n' # On remet IFS à newlines pour la boucle principale

    [[ -z "$vnet_name" ]] && continue
    echo "📊 VNet : $vnet_name"

    # Récupération JSON
    vnet_json=$(az network vnet show --ids "$vnet_id" --query "{
        prefixes: addressSpace.addressPrefixes,
        subnets: subnets[].{name:name, cidr:addressPrefix}
    }" -o json 2>/dev/null)

    # Extraction des préfixes en liste propre
    # jq -r outpute chaque item sur une nouvelle ligne
    prefixes_list=$(echo "$vnet_json" | jq -r '.prefixes[]')
    subnets_json=$(echo "$vnet_json" | jq -c '.subnets[]?') # -c pour compact (1 ligne par subnet json)

    # BOUCLE SUR LES PREFIXES (For loop, pas While)
    for prefix in $prefixes_list; do
        [[ -z "$prefix" || "$prefix" == "null" ]] && continue
        
        # echo "   -> Analyse Prefix : $prefix"

        total_prefix_ips=$(cidr_to_count "$prefix")
        
        subnet_count=0
        total_used=0
        total_reserved=0

        # BOUCLE SUR LES SUBNETS
        # Si subnets_json est vide, la boucle ne tourne pas
        if [[ -n "$subnets_json" ]]; then
            for subnet_row in $subnets_json; do
                s_name=$(echo "$subnet_row" | jq -r '.name')
                s_cidr=$(echo "$subnet_row" | jq -r '.cidr')

                # Test Python
                if subnet_in_prefix "$prefix" "$s_cidr"; then
                    ((subnet_count++))
                    
                    s_total=$(cidr_to_count "$s_cidr")
                    
                    # API Azure
                    avail=$(az network vnet subnet list-available-ips -g "$rg" --vnet-name "$vnet_name" -n "$s_name" --query "length(@)" -o tsv 2>/dev/null || echo 0)
                    [[ -z "$avail" ]] && avail=0

                    used=$((s_total - avail))
                    (( used < 0 )) && used=0

                    total_used=$((total_used + used))
                    total_reserved=$((total_reserved + AZURE_RESERVED_COUNT))
                fi
            done
        fi

        # Calculs finaux
        available_in_prefix=$((total_prefix_ips - total_used))
        
        # Pourcentage (via awk pour les float)
        usage_pct="0.00"
        if (( total_prefix_ips > 0 )); then
            usage_pct=$(awk "BEGIN {printf \"%.2f\", ($total_used / $total_prefix_ips) * 100}")
        fi

        # ECRITURE SECURISEE (echo >> fichier)
        # On construit la ligne d'abord pour être sûr
        csv_line="$vnet_name,$rg,$prefix,$subnet_count,$total_reserved,$total_used,$available_in_prefix,$usage_pct%"
        
        # Debug console visuel
        # echo "      📝 Ecriture : $csv_line"
        
        # Écriture fichier
        echo "$csv_line" >> "$OUTPUT_FILE"

    done # Fin boucle prefix
done # Fin boucle vnet

unset IFS # Reset du séparateur système

echo ""
echo "✅ Terminé !"
if [[ -s "$OUTPUT_FILE" ]]; then
    echo "📄 Fichier généré : $OUTPUT_FILE"
    echo "📝 Aperçu des 3 premières lignes :"
    head -n 4 "$OUTPUT_FILE"
else
    echo "❌ ERREUR CRITIQUE : Le fichier est vide."
fi
