#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION SANS SOUS-SHELL
#  v2.5 - Réécriture complète pour éviter les sous-shells
#  Objectif : Calculer l'usage réel incluant les 5 IPs réservées Azure
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Configuration
OUTPUT_FILE="Azure_VNet_Usage_v2_$(date +%Y%m%d_%H%M%S).csv"
AZURE_RESERVED_COUNT=5
DEBUG="${DEBUG:-true}"

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonction de logging
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
debug() { [[ "$DEBUG" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $1" >&2; }

#───────────────────────────────────────────────────────────────────────────────
# VÉRIFICATIONS PRÉLIMINAIRES
#───────────────────────────────────────────────────────────────────────────────

# Vérifier les dépendances
for cmd in az jq; do
    if ! command -v $cmd >/dev/null 2>&1; then
        error "$cmd non installé"
        exit 1
    fi
done

# Vérifier la connexion Azure
if ! az account show >/dev/null 2>&1; then
    error "Non connecté à Azure. Exécutez 'az login'"
    exit 1
fi

CURRENT_SUB=$(az account show --query "name" -o tsv)
log "🔐 Connecté à: $CURRENT_SUB"

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS MATHÉMATIQUES
#───────────────────────────────────────────────────────────────────────────────

cidr_to_count() {
    local mask=${1#*/}
    echo $(( 2 ** (32 - mask) ))
}

ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a*16777216) + (b*65536) + (c*256) + d ))
}

subnet_in_prefix() {
    local prefix=$1
    local subnet=$2
    local p_ip=${prefix%/*}
    local p_mask=${prefix#*/}
    local s_ip=${subnet%/*}
    local s_mask=${subnet#*/}

    if [ "$s_mask" -lt "$p_mask" ]; then
        return 1
    fi

    local p_int=$(ip_to_int "$p_ip")
    local s_int=$(ip_to_int "$s_ip")
    
    local shift=$(( 32 - p_mask ))
    local p_shifted=$(( p_int >> shift ))
    local s_shifted=$(( s_int >> shift ))
    
    [ "$p_shifted" -eq "$s_shifted" ]
}

get_available_ips() {
    local rg=$1 vnet=$2 subnet=$3
    local result
    
    result=$(az network vnet subnet list-available-ips \
        -g "$rg" --vnet-name "$vnet" -n "$subnet" \
        --query "length(@)" -o tsv 2>/dev/null || echo "0")
    
    echo "${result:-0}"
}

#───────────────────────────────────────────────────────────────────────────────
# TRAITEMENT PRINCIPAL SANS SOUS-SHELL
#───────────────────────────────────────────────────────────────────────────────

log "🚀 Démarrage de l'analyse des VNets Azure..."

# En-tête CSV
echo "VNet,ResourceGroup,Prefix,SubnetCount,UsedIPs,AvailableIPs,UsagePercent,ReservedIPs" > "$OUTPUT_FILE"

# Récupérer la liste des VNets dans un fichier temporaire
TEMP_VNETS=$(mktemp)
trap "rm -f $TEMP_VNETS" EXIT

log "🔍 Récupération de la liste des VNets..."
az network vnet list -o json > "$TEMP_VNETS" 2>/dev/null

VNET_COUNT=$(jq 'length' "$TEMP_VNETS")

if [[ "$VNET_COUNT" -eq 0 ]]; then
    warn "Aucun VNet trouvé"
    exit 0
fi

log "📝 $VNET_COUNT VNet(s) trouvé(s)"

# Traiter chaque VNet
for ((i=0; i<$VNET_COUNT; i++)); do
    # Extraire les informations du VNet
    vnet_name=$(jq -r ".[$i].name" "$TEMP_VNETS")
    rg=$(jq -r ".[$i].resourceGroup" "$TEMP_VNETS")
    vnet_id=$(jq -r ".[$i].id" "$TEMP_VNETS")
    
    log "📊 [$((i+1))/$VNET_COUNT] Analyse de : $vnet_name ($rg)"
    
    # Récupérer les détails du VNet
    TEMP_VNET_DETAIL=$(mktemp)
    az network vnet show --ids "$vnet_id" -o json > "$TEMP_VNET_DETAIL" 2>/dev/null
    
    # Récupérer les prefixes
    PREFIX_COUNT=$(jq '.addressSpace.addressPrefixes | length' "$TEMP_VNET_DETAIL")
    
    for ((p=0; p<$PREFIX_COUNT; p++)); do
        prefix=$(jq -r ".addressSpace.addressPrefixes[$p]" "$TEMP_VNET_DETAIL")
        
        debug "  Traitement du prefix: $prefix"
        
        total_prefix_ips=$(cidr_to_count "$prefix")
        subnet_count=0
        total_used_in_prefix=0
        reserved_ips_count=0
        
        # Récupérer les subnets
        SUBNET_COUNT=$(jq '.subnets | length' "$TEMP_VNET_DETAIL")
        
        for ((s=0; s<$SUBNET_COUNT; s++)); do
            s_name=$(jq -r ".subnets[$s].name" "$TEMP_VNET_DETAIL")
            s_cidr=$(jq -r ".subnets[$s].addressPrefix" "$TEMP_VNET_DETAIL")
            
            debug "    Vérification subnet: $s_name ($s_cidr)"
            
            if subnet_in_prefix "$prefix" "$s_cidr"; then
                ((subnet_count++))
                ((reserved_ips_count += AZURE_RESERVED_COUNT))
                
                subnet_total=$(cidr_to_count "$s_cidr")
                available_ips=$(get_available_ips "$rg" "$vnet_name" "$s_name")
                used_in_subnet=$((subnet_total - available_ips))
                
                if (( used_in_subnet < 0 )); then
                    used_in_subnet=0
                fi
                
                total_used_in_prefix=$((total_used_in_prefix + used_in_subnet))
                
                debug "      ✓ Match! Used: $used_in_subnet, Available: $available_ips"
            fi
        done
        
        # Calculer les statistiques
        available_in_prefix=$((total_prefix_ips - total_used_in_prefix))
        
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(awk "BEGIN {printf \"%.2f\", ($total_used_in_prefix / $total_prefix_ips) * 100}")
        else
            usage_percent="0.00"
        fi
        
        # Écrire la ligne dans le CSV
        echo "$vnet_name,$rg,$prefix,$subnet_count,$total_used_in_prefix,$available_in_prefix,$usage_percent,$reserved_ips_count" >> "$OUTPUT_FILE"
        
        debug "  ✓ Ligne ajoutée au CSV"
    done
    
    rm -f "$TEMP_VNET_DETAIL"
done

rm -f "$TEMP_VNETS"

#───────────────────────────────────────────────────────────────────────────────
# VÉRIFICATION ET RÉSUMÉ
#───────────────────────────────────────────────────────────────────────────────

LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
DATA_LINES=$((LINE_COUNT - 1))

log "📊 Résultat: $DATA_LINES ligne(s) de données écrites"

if [[ "$DATA_LINES" -gt 0 ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "📊 RÉSUMÉ DE L'UTILISATION DES VNETS AZURE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    awk -F, 'NR>1 {
        vnets[$1]=1
        total_used+=$5
        total_available+=$6
        prefixes++
    }
    END {
        if (NR > 1) {
            total_ips = total_used + total_available
            usage_pct = total_ips > 0 ? (total_used / total_ips) * 100 : 0
            
            printf "VNets analysés    : %d\n", length(vnets)
            printf "Préfixes réseau   : %d\n", prefixes
            printf "IPs totales       : %d\n", total_ips
            printf "IPs utilisées     : %d (%.2f%%)\n", total_used, usage_pct
            printf "IPs disponibles   : %d\n", total_available
        }
    }' "$OUTPUT_FILE"
    
    echo "═══════════════════════════════════════════════════════════════"
    
    # Afficher les premières lignes pour vérification
    echo ""
    echo "📄 Aperçu du fichier (5 premières lignes):"
    head -5 "$OUTPUT_FILE"
else
    error "Aucune donnée n'a pu être collectée"
    
    # Test de diagnostic
    echo ""
    echo "Test de diagnostic - Vérification d'un VNet:"
    az network vnet list --query "[0]" -o table
fi

echo ""
echo "📁 Fichier de sortie: $OUTPUT_FILE"
echo ""

exit 0
