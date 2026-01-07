#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION CORRIGÉE
#  v2.4 - Correction du problème de sous-shell
#  Objectif : Calculer l'usage réel incluant les 5 IPs réservées Azure
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Configuration
OUTPUT_FILE="Azure_VNet_Usage_v2_$(date +%Y%m%d_%H%M%S).csv"
JSON_FILE="${OUTPUT_FILE%.csv}.json"
HTML_FILE="${OUTPUT_FILE%.csv}.html"
AZURE_RESERVED_COUNT=5
PARALLEL_JOBS=4
RETRY_COUNT=3
EXPORT_JSON="${EXPORT_JSON:-true}"
EXPORT_HTML="${EXPORT_HTML:-true}"
DEBUG="${DEBUG:-true}"

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonction de logging
log() { 
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

warn() { 
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() { 
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

debug() { 
    [[ "$DEBUG" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $1" >&2
}

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

# Afficher le compte actuel
CURRENT_SUB=$(az account show --query "name" -o tsv)
log "🔐 Connecté à: $CURRENT_SUB"

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS MATHÉMATIQUES
#───────────────────────────────────────────────────────────────────────────────

# Convertir CIDR en nombre total d'IPs
cidr_to_count() {
    local mask=${1#*/}
    echo $(( 2 ** (32 - mask) ))
}

# Convertir IP en entier
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a*16777216) + (b*65536) + (c*256) + d ))
}

# Vérifie si subnet est dans prefix
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
    
    if [ "$p_shifted" -eq "$s_shifted" ]; then
        return 0
    else
        return 1
    fi
}

# Récupérer les IPs disponibles avec retry
get_available_ips() {
    local rg=$1 
    local vnet=$2 
    local subnet=$3
    local retries=$RETRY_COUNT
    local result
    
    for ((i=1; i<=retries; i++)); do
        if result=$(timeout 30 az network vnet subnet list-available-ips \
            -g "$rg" --vnet-name "$vnet" -n "$subnet" \
            --query "length(@)" -o tsv 2>/dev/null); then
            echo "${result:-0}"
            return 0
        fi
        
        if (( i < retries )); then
            debug "Retry $i/$retries pour $subnet..."
            sleep 2
        fi
    done
    
    debug "Impossible de récupérer les IPs disponibles pour $subnet"
    echo "0"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTION DE TRAITEMENT D'UN VNET (CORRIGÉE)
#───────────────────────────────────────────────────────────────────────────────

process_vnet() {
    local vnet_name=$1
    local rg=$2
    local vnet_id=$3
    
    if [[ -z "$vnet_name" ]] || [[ "$vnet_name" == "null" ]]; then
        return
    fi
    
    log "📊 Analyse de : $vnet_name ($rg)"

    # Récupérer les données du VNet
    local vnet_json
    vnet_json=$(az network vnet show --ids "$vnet_id" -o json 2>/dev/null)

    if [[ -z "$vnet_json" ]] || [[ "$vnet_json" == "null" ]]; then
        warn "Impossible de récupérer les données pour $vnet_name"
        return
    fi

    # Extraire les prefixes et subnets
    local prefixes
    prefixes=$(echo "$vnet_json" | jq -r '.addressSpace.addressPrefixes[]?' 2>/dev/null || echo "")
    
    if [[ -z "$prefixes" ]]; then
        warn "Aucun prefix trouvé pour $vnet_name"
        return
    fi

    # Pour chaque Prefix du VNet
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue

        local total_prefix_ips=$(cidr_to_count "$prefix")
        local subnet_count=0
        local total_used_in_prefix=0
        local reserved_ips_count=0

        debug "Traitement du prefix: $prefix (Total IPs: $total_prefix_ips)"

        # Extraire les subnets dans un tableau pour éviter le sous-shell
        local subnets_array=()
        while IFS= read -r subnet_data; do
            [[ -n "$subnet_data" ]] && subnets_array+=("$subnet_data")
        done < <(echo "$vnet_json" | jq -c '.subnets[]?' 2>/dev/null)

        # Parcourir les subnets sans sous-shell
        for subnet_data in "${subnets_array[@]}"; do
            [[ -z "$subnet_data" ]] && continue
            
            local s_name s_cidr
            s_name=$(echo "$subnet_data" | jq -r '.name')
            s_cidr=$(echo "$subnet_data" | jq -r '.addressPrefix')

            debug "  Vérification subnet: $s_name ($s_cidr)"

            # Vérifier l'appartenance mathématique
            if subnet_in_prefix "$prefix" "$s_cidr"; then
                ((subnet_count++))
                ((reserved_ips_count += AZURE_RESERVED_COUNT))
                
                local subnet_total=$(cidr_to_count "$s_cidr")
                local available_ips=$(get_available_ips "$rg" "$vnet_name" "$s_name")
                local used_in_subnet=$((subnet_total - available_ips))
                
                if (( used_in_subnet < 0 )); then
                    used_in_subnet=0
                fi

                total_used_in_prefix=$((total_used_in_prefix + used_in_subnet))
                
                debug "  └─ Match! Subnet: $s_name | Total: $subnet_total | Available: $available_ips | Used: $used_in_subnet"
            else
                debug "  └─ No match for subnet: $s_name"
            fi
        done

        # Calculs finaux
        local available_in_prefix=$((total_prefix_ips - total_used_in_prefix))
        local usage_percent="0.00"
        
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(awk "BEGIN {printf \"%.2f\", ($total_used_in_prefix / $total_prefix_ips) * 100}")
        fi

        # Écriture dans le fichier CSV
        debug "Écriture CSV: VNet=$vnet_name, RG=$rg, Prefix=$prefix, Subnets=$subnet_count, Used=$total_used_in_prefix, Available=$available_in_prefix"
        
        echo "$vnet_name,$rg,$prefix,$subnet_count,$total_used_in_prefix,$available_in_prefix,$usage_percent,$reserved_ips_count" >> "$OUTPUT_FILE"

        # Vérifier que l'écriture s'est bien faite
        if [[ $? -eq 0 ]]; then
            debug "✓ Ligne écrite avec succès dans $OUTPUT_FILE"
        else
            error "✗ Échec de l'écriture dans $OUTPUT_FILE"
        fi

        # Alerte si utilisation élevée
        local usage_int=${usage_percent%.*}
        if (( usage_int > 80 )); then
            warn "⚠️  Utilisation élevée (${usage_percent}%) pour $vnet_name/$prefix"
        fi

    done <<< "$prefixes"
}

#───────────────────────────────────────────────────────────────────────────────
# TRAITEMENT PRINCIPAL
#───────────────────────────────────────────────────────────────────────────────

log "🚀 Démarrage de l'analyse des VNets Azure..."

# En-tête CSV
echo "VNet,ResourceGroup,Prefix,SubnetCount,UsedIPs,AvailableIPs,UsagePercent,ReservedIPs" > "$OUTPUT_FILE"

# Vérifier que le fichier existe et est accessible
if [[ ! -f "$OUTPUT_FILE" ]]; then
    error "Impossible de créer le fichier $OUTPUT_FILE"
    exit 1
fi

debug "Fichier de sortie créé: $OUTPUT_FILE"

# Récupérer la liste des VNets
log "🔍 Récupération de la liste des VNets..."

VNET_LIST=$(az network vnet list -o json 2>/dev/null || echo "[]")
VNET_COUNT=$(echo "$VNET_LIST" | jq 'length')

if [[ "$VNET_COUNT" -eq 0 ]]; then
    warn "Aucun VNet trouvé dans la souscription"
    exit 0
fi

log "📝 $VNET_COUNT VNet(s) trouvé(s)"

# Export des fonctions
export -f cidr_to_count ip_to_int subnet_in_prefix get_available_ips log warn error debug
export OUTPUT_FILE AZURE_RESERVED_COUNT RETRY_COUNT DEBUG RED GREEN YELLOW BLUE NC

# Traiter chaque VNet
vnet_index=0
echo "$VNET_LIST" | jq -c '.[]' | while IFS= read -r vnet_item; do
    ((vnet_index++))
    
    vnet_name=$(echo "$vnet_item" | jq -r '.name')
    rg=$(echo "$vnet_item" | jq -r '.resourceGroup')
    vnet_id=$(echo "$vnet_item" | jq -r '.id')
    
    debug "[$vnet_index/$VNET_COUNT] Processing VNet: $vnet_name"
    
    if [[ -n "$vnet_name" ]] && [[ "$vnet_name" != "null" ]]; then
        process_vnet "$vnet_name" "$rg" "$vnet_id"
    fi
done

# Vérification finale
LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
DATA_LINES=$((LINE_COUNT - 1))

log "📊 Résultat: $DATA_LINES ligne(s) de données écrites"

if [[ "$DATA_LINES" -eq 0 ]]; then
    error "Aucune donnée n'a été écrite dans le fichier CSV"
    
    # Diagnostic supplémentaire
    echo ""
    echo "🔍 Diagnostic complet:"
    echo "1. Test direct d'un VNet:"
    
    # Récupérer le premier VNet pour test
    TEST_VNET=$(az network vnet list --query "[0].name" -o tsv 2>/dev/null)
    TEST_RG=$(az network vnet list --query "[0].resourceGroup" -o tsv 2>/dev/null)
    
    if [[ -n "$TEST_VNET" ]]; then
        echo "   VNet de test: $TEST_VNET (RG: $TEST_RG)"
        
        # Afficher les détails
        az network vnet show -n "$TEST_VNET" -g "$TEST_RG" --query "{name:name, prefixes:addressSpace.addressPrefixes, subnetCount:length(subnets)}" -o table
    fi
fi

#───────────────────────────────────────────────────────────────────────────────
# GÉNÉRATION DU RAPPORT DE SYNTHÈSE
#───────────────────────────────────────────────────────────────────────────────

if [[ "$DATA_LINES" -gt 0 ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "📊 RÉSUMÉ DE L'UTILISATION DES VNETS AZURE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    awk -F, 'NR>1 {
        vnets[$1]=1
        rgs[$2]=1
        prefixes++
        total_subnets+=$4
        total_used+=$5
        total_available+=$6
        total_reserved+=$8
    }
    END {
        if (NR > 1) {
            total_ips = total_used + total_available
            usage_pct = total_ips > 0 ? (total_used / total_ips) * 100 : 0
            
            printf "📍 VNets analysés     : %d\n", length(vnets)
            printf "📍 Resource Groups    : %d\n", length(rgs)
            printf "📍 Préfixes réseau    : %d\n", prefixes
            printf "📍 Subnets totaux     : %d\n", total_subnets
            printf "\n"
            printf "💾 IPs totales        : %d\n", total_ips
            printf "💾 IPs utilisées      : %d (%.2f%%)\n", total_used, usage_pct
            printf "💾 IPs disponibles    : %d\n", total_available
        }
    }' "$OUTPUT_FILE"
    
    echo "═══════════════════════════════════════════════════════════════"
fi

# Afficher les premières lignes du CSV pour vérification
if [[ "$DEBUG" == "true" ]] && [[ "$DATA_LINES" -gt 0 ]]; then
    echo ""
    echo "📄 Aperçu du fichier CSV (5 premières lignes):"
    head -5 "$OUTPUT_FILE"
fi

echo ""
echo "📁 Fichier généré: $OUTPUT_FILE"
echo ""

exit 0
