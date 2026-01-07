#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION DEBUG
#  v2.3 - Avec diagnostic complet
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
DEBUG="${DEBUG:-true}"  # Activé par défaut pour le diagnostic

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
        echo "Installation suggérée:"
        [[ "$cmd" == "az" ]] && echo "  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        [[ "$cmd" == "jq" ]] && echo "  sudo apt-get install jq  # ou brew install jq"
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
SUB_ID=$(az account show --query "id" -o tsv)
log "🔐 Connecté à: $CURRENT_SUB (ID: $SUB_ID)"

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS MATHÉMATIQUES
#───────────────────────────────────────────────────────────────────────────────

# Convertir CIDR en nombre total d'IPs
cidr_to_count() {
    local mask=${1#*/}
    local count=$(( 2 ** (32 - mask) ))
    echo "$count"
}

# Convertir IP en entier
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    local result=$(( (a*16777216) + (b*65536) + (c*256) + d ))
    echo "$result"
}

# Vérifie si subnet est dans prefix
subnet_in_prefix() {
    local prefix=$1
    local subnet=$2
    local p_ip=${prefix%/*}
    local p_mask=${prefix#*/}
    local s_ip=${subnet%/*}
    local s_mask=${subnet#*/}

    # Le subnet doit avoir un masque >= au prefix
    if [ "$s_mask" -lt "$p_mask" ]; then
        return 1
    fi

    # Comparaison simple basée sur les préfixes des IPs
    local p_int=$(ip_to_int "$p_ip")
    local s_int=$(ip_to_int "$s_ip")
    
    # On décale les deux nombres pour ne garder que les bits du réseau
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
            echo "$result"
            return 0
        fi
        
        if (( i < retries )); then
            debug "Retry $i/$retries pour $subnet..."
            sleep 2
        fi
    done
    
    debug "Impossible de récupérer les IPs disponibles pour $subnet (utilisation de 0)"
    echo "0"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTION DE TRAITEMENT D'UN VNET
#───────────────────────────────────────────────────────────────────────────────

process_vnet() {
    local vnet_name=$1
    local rg=$2
    local vnet_id=$3
    
    if [[ -z "$vnet_name" ]] || [[ "$vnet_name" == "null" ]]; then
        debug "VNet name vide, skip"
        return
    fi
    
    log "📊 Analyse de : $vnet_name ($rg)"

    # Récupérer les données du VNet
    local vnet_json
    debug "Récupération des données pour VNet ID: $vnet_id"
    
    vnet_json=$(az network vnet show --ids "$vnet_id" --query "{
        prefixes: addressSpace.addressPrefixes,
        subnets: subnets[].{name:name, cidr:addressPrefix}
    }" -o json 2>/dev/null)

    debug "JSON reçu: ${vnet_json:0:100}..."  # Afficher les 100 premiers caractères

    # Vérifier si le VNet existe et a des données
    if [[ -z "$vnet_json" ]] || [[ "$vnet_json" == "null" ]]; then
        warn "Impossible de récupérer les données pour $vnet_name"
        return
    fi

    # Extraire les tableaux
    local prefixes subnets_json
    prefixes=$(echo "$vnet_json" | jq -r '.prefixes[]?' 2>/dev/null || echo "")
    subnets_json=$(echo "$vnet_json" | jq -c '.subnets[]?' 2>/dev/null || echo "")

    debug "Prefixes trouvés: $prefixes"
    
    if [[ -z "$prefixes" ]]; then
        warn "Aucun prefix trouvé pour $vnet_name"
        return
    fi

    # Pour chaque Prefix du VNet
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue

        local total_prefix_ips
        total_prefix_ips=$(cidr_to_count "$prefix")
        local subnet_count=0
        local total_used_in_prefix=0
        local reserved_ips_count=0

        debug "Traitement du prefix: $prefix (Total IPs: $total_prefix_ips)"

        # Parcourir les subnets
        echo "$vnet_json" | jq -c '.subnets[]?' 2>/dev/null | while IFS= read -r subnet_line; do
            [[ -z "$subnet_line" ]] && continue
            
            local s_name s_cidr
            s_name=$(echo "$subnet_line" | jq -r '.name')
            s_cidr=$(echo "$subnet_line" | jq -r '.cidr')

            debug "  Vérification subnet: $s_name ($s_cidr)"

            # Vérifier l'appartenance mathématique
            if subnet_in_prefix "$prefix" "$s_cidr"; then
                ((subnet_count++))
                ((reserved_ips_count += AZURE_RESERVED_COUNT))
                
                local subnet_total
                subnet_total=$(cidr_to_count "$s_cidr")

                # Récupérer les IPs disponibles
                local available_ips
                available_ips=$(get_available_ips "$rg" "$vnet_name" "$s_name")

                # Calcul des IPs utilisées
                local used_in_subnet=$((subnet_total - available_ips))
                
                # Sécurité pour ne pas avoir de nombres négatifs
                if (( used_in_subnet < 0 )); then
                    used_in_subnet=0
                fi

                total_used_in_prefix=$((total_used_in_prefix + used_in_subnet))
                
                debug "  └─ Subnet: $s_name | CIDR: $s_cidr | Total: $subnet_total | Available: $available_ips | Used: $used_in_subnet"
            fi
        done

        # Calcul final
        local available_in_prefix=$((total_prefix_ips - total_used_in_prefix))
        
        # Calcul du pourcentage
        local usage_percent="0.00"
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(awk "BEGIN {printf \"%.2f\", ($total_used_in_prefix / $total_prefix_ips) * 100}")
        fi

        # Écriture CSV
        debug "Écriture dans CSV: $vnet_name,$rg,$prefix,..."
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" \
            "$total_used_in_prefix" "$available_in_prefix" \
            "$usage_percent" "$reserved_ips_count" >> "$OUTPUT_FILE"

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

# Récupérer la liste des VNets avec plus de debug
log "🔍 Récupération de la liste des VNets..."

# Test de la commande az
debug "Test de la commande az network vnet list..."
VNET_LIST=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o json 2>/dev/null || echo "[]")
debug "VNets JSON (premiers 200 chars): ${VNET_LIST:0:200}"

VNET_COUNT=$(echo "$VNET_LIST" | jq 'length' 2>/dev/null || echo "0")

if [[ "$VNET_COUNT" -eq 0 ]]; then
    warn "Aucun VNet trouvé dans la souscription"
    
    # Essayer une méthode alternative
    debug "Tentative avec format TSV..."
    VNET_TSV=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv 2>&1)
    debug "Résultat TSV: $VNET_TSV"
    
    exit 0
fi

log "📝 $VNET_COUNT VNet(s) trouvé(s)"

# Export des fonctions pour le traitement
export -f cidr_to_count ip_to_int subnet_in_prefix get_available_ips process_vnet log warn error debug
export OUTPUT_FILE AZURE_RESERVED_COUNT RETRY_COUNT DEBUG RED GREEN YELLOW BLUE NC

# Traitement séquentiel avec plus de debug
log "🔄 Traitement séquentiel des VNets"

# Utiliser JSON pour le parsing qui est plus fiable
echo "$VNET_LIST" | jq -r '.[] | "\(.name)\t\(.rg)\t\(.id)"' 2>/dev/null | while IFS=$'\t' read -r vnet_name rg vnet_id; do
    debug "Processing: vnet_name='$vnet_name', rg='$rg', vnet_id='$vnet_id'"
    
    if [[ -n "$vnet_name" ]] && [[ "$vnet_name" != "null" ]]; then
        process_vnet "$vnet_name" "$rg" "$vnet_id"
    else
        debug "Skipping empty vnet entry"
    fi
done

# Alternative si la méthode ci-dessus ne fonctionne pas
if [[ $(wc -l < "$OUTPUT_FILE") -eq 1 ]]; then
    warn "Aucune donnée écrite, tentative avec méthode alternative..."
    
    # Méthode alternative directe
    az network vnet list -o tsv --query "[].{name:name, rg:resourceGroup, id:id}" | while IFS=$'\t' read -r vnet_name rg vnet_id; do
        debug "Alternative processing: $vnet_name"
        if [[ -n "$vnet_name" ]]; then
            process_vnet "$vnet_name" "$rg" "$vnet_id"
        fi
    done
fi

#───────────────────────────────────────────────────────────────────────────────
# VÉRIFICATION DES RÉSULTATS
#───────────────────────────────────────────────────────────────────────────────

LINE_COUNT=$(wc -l < "$OUTPUT_FILE")
debug "Nombre de lignes dans le fichier CSV: $LINE_COUNT"

if [[ "$LINE_COUNT" -eq 1 ]]; then
    error "Aucune donnée n'a été écrite dans le fichier CSV"
    echo ""
    echo "🔍 Diagnostic:"
    echo "1. Vérifiez que vous avez des VNets dans votre souscription"
    echo "2. Exécutez: az network vnet list"
    echo "3. Vérifiez vos permissions Azure"
    echo ""
    
    # Test direct
    echo "Test direct de la commande Azure CLI:"
    az network vnet list --query "[0:2]" -o table
fi

#───────────────────────────────────────────────────────────────────────────────
# GÉNÉRATION DU RAPPORT DE SYNTHÈSE
#───────────────────────────────────────────────────────────────────────────────

generate_summary() {
    local lines=$(wc -l < "$OUTPUT_FILE")
    
    if [[ "$lines" -le 1 ]]; then
        warn "Pas assez de données pour générer un résumé"
        return
    fi
    
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
        
        usage=strtonum($7)
        if (usage > 80) high_usage[NR]=$1"/"$3" ("$7"%)"
        if (usage > 90) critical_usage[NR]=$1"/"$3" ("$7"%)"
    }
    END {
        if (NR <= 1) {
            print "Aucune donnée à analyser"
            exit
        }
        
        total_ips = total_used + total_available
        
        if (total_ips > 0) {
            usage_pct = (total_used / total_ips) * 100
            real_used = total_used - total_reserved
            real_usage_pct = (real_used / total_ips) * 100
        } else {
            usage_pct = 0
            real_used = 0
            real_usage_pct = 0
        }
        
        printf "📍 Souscription analysée\n"
        printf "├─ VNets             : %d\n", length(vnets)
        printf "├─ Resource Groups   : %d\n", length(rgs)
        printf "├─ Préfixes réseau   : %d\n", prefixes
        printf "└─ Subnets totaux    : %d\n\n", total_subnets
        
        if (total_ips > 0) {
            printf "💾 UTILISATION DES IPs\n"
            printf "├─ IPs totales       : %d\n", total_ips
            printf "├─ IPs utilisées     : %d (%.2f%%)\n", total_used, usage_pct
            printf "│  ├─ Réservées Azure: %d\n", total_reserved
            printf "│  └─ Réellement utilisées: %d (%.2f%%)\n", real_used, real_usage_pct
            printf "└─ IPs disponibles   : %d\n\n", total_available
        }
    }' "$OUTPUT_FILE"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

# Appeler la fonction de résumé
generate_summary

# Affichage final
echo ""
echo "📁 Fichiers générés:"
echo "   📄 CSV: $OUTPUT_FILE"
echo ""

# Afficher le contenu du CSV pour debug
if [[ "$DEBUG" == "true" ]]; then
    echo "Contenu du fichier CSV (10 premières lignes):"
    head -10 "$OUTPUT_FILE"
fi

exit 0
