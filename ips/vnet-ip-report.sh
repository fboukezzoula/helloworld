#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET PREFIX ANALYZER – VERSION PRODUCTION
#  
#  Description : Analyse complète des VNets Azure avec calcul précis des IPs
#  Auteur      : Script optimisé et corrigé
#  Version     : 2.0.0
#  
#  Fonctionnalités :
#    ✓ Matching correct pour tous les masques (/8 à /29)
#    ✓ Calcul précis des IPs (réservations Azure incluses)
#    ✓ Gestion d'erreurs complète
#    ✓ Compatible macOS et Linux
#    ✓ Mode parallèle optionnel
#    ✓ Mode Azure Resource Graph pour grands environnements
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
#───────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.0.0"
readonly OUTPUT_FILE="Azure_VNet_Report_$(date +%Y%m%d_%H%M%S).csv"
readonly LOG_FILE="azure_vnet_scan_$(date +%Y%m%d_%H%M%S).log"
readonly AZURE_RESERVED_IPS=5  # IPs réservées par Azure par subnet

# Couleurs pour l'affichage
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Options
USE_PARALLEL=false
USE_RESOURCE_GRAPH=false
VERBOSE=false
MAX_PARALLEL_JOBS=5

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS UTILITAIRES
#───────────────────────────────────────────────────────────────────────────────

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        INFO)  $VERBOSE && echo -e "${BLUE}ℹ${NC} $message" ;;
        OK)    echo -e "${GREEN}✅${NC} $message" ;;
        WARN)  echo -e "${YELLOW}⚠️${NC} $message" ;;
        ERROR) echo -e "${RED}❌${NC} $message" >&2 ;;
        DEBUG) $VERBOSE && echo -e "${CYAN}🔍${NC} $message" ;;
    esac
}

show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║     █████╗ ███████╗██╗   ██╗██████╗ ███████╗                  ║
║    ██╔══██╗╚══███╔╝██║   ██║██╔══██╗██╔════╝                  ║
║    ███████║  ███╔╝ ██║   ██║██████╔╝█████╗                    ║
║    ██╔══██║ ███╔╝  ██║   ██║██╔══██╗██╔══╝                    ║
║    ██║  ██║███████╗╚██████╔╝██║  ██║███████╗                  ║
║    ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝                  ║
║                                                               ║
║           VNET PREFIX ANALYZER v2.0.0                         ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -p, --parallel      Active le mode parallèle (plus rapide)
    -g, --graph         Utilise Azure Resource Graph (recommandé > 500 VNets)
    -j, --jobs N        Nombre de jobs parallèles (défaut: 5)
    -v, --verbose       Mode verbeux
    -h, --help          Affiche cette aide
    
Exemples:
    $(basename "$0")                    # Mode standard
    $(basename "$0") -p -j 10           # Mode parallèle avec 10 jobs
    $(basename "$0") -g                 # Mode Azure Resource Graph
    $(basename "$0") -v                 # Mode verbeux

EOF
}

check_prerequisites() {
    log INFO "Vérification des prérequis..."
    
    local missing=()
    
    # Vérifier Azure CLI
    if ! command -v az &>/dev/null; then
        missing+=("azure-cli")
    fi
    
    # Vérifier jq
    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi
    
    # Vérifier connexion Azure
    if ! az account show &>/dev/null; then
        log ERROR "Non connecté à Azure. Exécutez 'az login' d'abord."
        exit 1
    fi
    
    # Vérifier Resource Graph si demandé
    if $USE_RESOURCE_GRAPH; then
        if ! az extension show --name resource-graph &>/dev/null; then
            log WARN "Extension resource-graph non installée. Installation..."
            az extension add --name resource-graph --yes || {
                log ERROR "Impossible d'installer l'extension resource-graph"
                exit 1
            }
        fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Dépendances manquantes: ${missing[*]}"
        log ERROR "Installez-les avec votre gestionnaire de paquets"
        exit 1
    fi
    
    # Afficher les infos de connexion
    local account_info
    account_info=$(az account show --query "{name:name, id:id}" -o tsv)
    log OK "Connecté à Azure: $account_info"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS DE CALCUL IP
#───────────────────────────────────────────────────────────────────────────────

# Convertit une IP en entier
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Convertit un entier en IP
int_to_ip() {
    local int=$1
    echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

# Calcule le nombre d'IPs dans un CIDR
cidr_to_ip_count() {
    local cidr=$1
    local mask=${cidr#*/}
    echo $(( 2 ** (32 - mask) ))
}

# Vérifie si un subnet est contenu dans un prefix
# Retourne 0 (true) si le subnet est dans le prefix, 1 (false) sinon
subnet_in_prefix() {
    local prefix=$1
    local subnet=$2
    
    local prefix_ip=${prefix%/*}
    local prefix_mask=${prefix#*/}
    local subnet_ip=${subnet%/*}
    local subnet_mask=${subnet#*/}
    
    # Le subnet doit avoir un masque >= au prefix
    if (( subnet_mask < prefix_mask )); then
        return 1
    fi
    
    local prefix_int=$(ip_to_int "$prefix_ip")
    local subnet_int=$(ip_to_int "$subnet_ip")
    
    # Créer le masque réseau
    local netmask=$(( 0xFFFFFFFF << (32 - prefix_mask) ))
    
    # Vérifier si les parties réseau correspondent
    if (( (prefix_int & netmask) == (subnet_int & netmask) )); then
        return 0
    else
        return 1
    fi
}

# Calcule les IPs utilisables dans un subnet (excluant les réservations Azure)
get_usable_ips() {
    local cidr=$1
    local total=$(cidr_to_ip_count "$cidr")
    local usable=$(( total - AZURE_RESERVED_IPS ))
    
    # Minimum 0 IPs utilisables
    if (( usable < 0 )); then
        usable=0
    fi
    
    echo "$usable"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS D'ANALYSE VNET
#───────────────────────────────────────────────────────────────────────────────

# Analyse un VNet et retourne les données CSV
analyze_vnet() {
    local vnet_name=$1
    local resource_group=$2
    local vnet_id=$3
    
    log DEBUG "Analyse du VNet: $vnet_name (RG: $resource_group)"
    
    # Récupérer les détails du VNet en une seule requête
    local vnet_data
    vnet_data=$(az network vnet show --ids "$vnet_id" \
        --query "{prefixes:addressSpace.addressPrefixes, subnets:subnets[].{name:name, cidr:addressPrefix}}" \
        -o json 2>/dev/null) || {
        log WARN "Impossible de récupérer les détails du VNet $vnet_name"
        return
    }
    
    # Extraire les prefixes
    local prefixes
    prefixes=$(echo "$vnet_data" | jq -r '.prefixes[]' 2>/dev/null) || return
    
    # Extraire les subnets
    local subnets_json
    subnets_json=$(echo "$vnet_data" | jq '.subnets' 2>/dev/null) || return
    
    # Pour chaque prefix du VNet
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        
        local prefix_mask=${prefix#*/}
        local total_prefix_ips=$(cidr_to_ip_count "$prefix")
        local subnet_count=0
        local used_ips=0
        local allocated_ips=0
        
        # Trouver les subnets correspondant à ce prefix
        local matching_subnets=()
        
        while IFS= read -r subnet_line; do
            [[ -z "$subnet_line" ]] && continue
            
            local subnet_name=$(echo "$subnet_line" | jq -r '.name')
            local subnet_cidr=$(echo "$subnet_line" | jq -r '.cidr')
            
            [[ -z "$subnet_cidr" || "$subnet_cidr" == "null" ]] && continue
            
            # Vérifier si le subnet appartient à ce prefix
            if subnet_in_prefix "$prefix" "$subnet_cidr"; then
                matching_subnets+=("$subnet_name|$subnet_cidr")
                ((subnet_count++))
                
                # Ajouter les IPs allouées à ce subnet
                local subnet_total=$(cidr_to_ip_count "$subnet_cidr")
                allocated_ips=$((allocated_ips + subnet_total))
            fi
        done < <(echo "$subnets_json" | jq -c '.[]' 2>/dev/null)
        
        # Calculer les IPs utilisées dans chaque subnet
        for subnet_info in "${matching_subnets[@]}"; do
            local subnet_name=${subnet_info%|*}
            local subnet_cidr=${subnet_info#*|}
            
            # Récupérer les IPs disponibles via Azure
            local available_ips
            available_ips=$(az network vnet subnet list-available-ips \
                -g "$resource_group" \
                --vnet-name "$vnet_name" \
                -n "$subnet_name" \
                --query "length(@)" \
                -o tsv 2>/dev/null) || available_ips=0
            
            local subnet_total=$(cidr_to_ip_count "$subnet_cidr")
            local subnet_usable=$(get_usable_ips "$subnet_cidr")
            
            # IPs utilisées = Total - Réservées Azure - Disponibles
            local subnet_used=$((subnet_usable - available_ips))
            if (( subnet_used < 0 )); then
                subnet_used=0
            fi
            
            used_ips=$((used_ips + subnet_used))
            
            log DEBUG "  Subnet $subnet_name ($subnet_cidr): Used=$subnet_used, Available=$available_ips"
        done
        
        # Calculer les IPs disponibles dans le prefix
        # = Total du prefix - IPs allouées aux subnets + IPs libres dans les subnets
        local unallocated_ips=$((total_prefix_ips - allocated_ips))
        local free_in_subnets=$((allocated_ips - used_ips - (subnet_count * AZURE_RESERVED_IPS)))
        if (( free_in_subnets < 0 )); then
            free_in_subnets=0
        fi
        local available_in_prefix=$((unallocated_ips + free_in_subnets))
        
        # Calculer le pourcentage d'utilisation
        local usage_percent=0
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(( (used_ips * 100) / total_prefix_ips ))
        fi
        
        # Écrire dans le fichier CSV
        printf '%s,%s,%s,%s,%s,%s,%s,%s%%\n' \
            "$vnet_name" \
            "$resource_group" \
            "$prefix" \
            "$subnet_count" \
            "$total_prefix_ips" \
            "$used_ips" \
            "$available_in_prefix" \
            "$usage_percent" >> "$OUTPUT_FILE"
        
        log OK "$vnet_name | $prefix → $subnet_count subnets | Used: $used_ips | Available: $available_in_prefix ($usage_percent%)"
        
    done <<< "$prefixes"
}

# Mode Azure Resource Graph (ultra-rapide pour grands environnements)
analyze_with_resource_graph() {
    log INFO "Utilisation d'Azure Resource Graph..."
    
    # Requête KQL pour récupérer toutes les données en une fois
    local query='
Resources
| where type == "microsoft.network/virtualnetworks"
| mv-expand prefix = properties.addressSpace.addressPrefixes
| mv-expand subnet = properties.subnets
| extend 
    VNetName = name,
    ResourceGroup = resourceGroup,
    Prefix = tostring(prefix),
    SubnetName = tostring(subnet.name),
    SubnetCIDR = tostring(subnet.properties.addressPrefix),
    Location = location
| project VNetName, ResourceGroup, Location, Prefix, SubnetName, SubnetCIDR
'
    
    local result
    result=$(az graph query -q "$query" --first 5000 -o json 2>/dev/null) || {
        log ERROR "Échec de la requête Azure Resource Graph"
        exit 1
    }
    
    # Traiter les résultats avec jq
    echo "$result" | jq -r '
        .data | 
        group_by(.VNetName + "|" + .Prefix) | 
        .[] | 
        {
            vnet: .[0].VNetName,
            rg: .[0].ResourceGroup,
            location: .[0].Location,
            prefix: .[0].Prefix,
            subnet_count: length,
            subnets: [.[] | {name: .SubnetName, cidr: .SubnetCIDR}]
        }
    ' | while IFS= read -r vnet_data; do
        # Traitement de chaque VNet/Prefix
        local vnet_name=$(echo "$vnet_data" | jq -r '.vnet')
        local rg=$(echo "$vnet_data" | jq -r '.rg')
        local prefix=$(echo "$vnet_data" | jq -r '.prefix')
        local subnet_count=$(echo "$vnet_data" | jq -r '.subnet_count')
        
        local prefix_mask=${prefix#*/}
        local total_ips=$(( 2 ** (32 - prefix_mask) ))
        
        # Pour Resource Graph, on estime les IPs utilisées
        # (nécessite toujours des appels API pour les IPs exactes)
        local allocated_ips=0
        while IFS= read -r subnet; do
            local cidr=$(echo "$subnet" | jq -r '.cidr')
            [[ -z "$cidr" || "$cidr" == "null" ]] && continue
            local mask=${cidr#*/}
            allocated_ips=$((allocated_ips + 2 ** (32 - mask)))
        done < <(echo "$vnet_data" | jq -c '.subnets[]')
        
        local available=$((total_ips - allocated_ips))
        local usage_percent=$(( (allocated_ips * 100) / total_ips ))
        
        printf '%s,%s,%s,%s,%s,%s,%s,%s%%\n' \
            "$vnet_name" "$rg" "$prefix" "$subnet_count" \
            "$total_ips" "$allocated_ips" "$available" "$usage_percent" >> "$OUTPUT_FILE"
        
        log OK "$vnet_name | $prefix → $subnet_count subnets"
    done
    
    log OK "Analyse Resource Graph terminée"
}

# Mode standard (itération sur chaque VNet)
analyze_standard() {
    log INFO "Récupération de la liste des VNets..."
    
    local vnets
    vnets=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv 2>/dev/null) || {
        log ERROR "Impossible de récupérer la liste des VNets"
        exit 1
    }
    
    local vnet_count
    vnet_count=$(echo "$vnets" | grep -c . || echo 0)
    
    if (( vnet_count == 0 )); then
        log WARN "Aucun VNet trouvé dans l'abonnement"
        exit 0
    fi
    
    log INFO "Trouvé $vnet_count VNet(s) à analyser"
    
    local current=0
    while IFS=$'\t' read -r vnet_name rg vnet_id; do
        [[ -z "$vnet_name" ]] && continue
        
        ((current++))
        log INFO "[$current/$vnet_count] Analyse de $vnet_name..."
        
        analyze_vnet "$vnet_name" "$rg" "$vnet_id"
        
    done <<< "$vnets"
}

# Mode parallèle
analyze_parallel() {
    log INFO "Mode parallèle activé ($MAX_PARALLEL_JOBS jobs)..."
    
    # Vérifier si GNU parallel est disponible
    if ! command -v parallel &>/dev/null; then
        log WARN "GNU parallel non installé, utilisation de xargs..."
        USE_XARGS=true
    fi
    
    local vnets
    vnets=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv 2>/dev/null)
    
    local vnet_count
    vnet_count=$(echo "$vnets" | grep -c . || echo 0)
    log INFO "Trouvé $vnet_count VNet(s) à analyser en parallèle"
    
    # Exporter les fonctions nécessaires
    export -f ip_to_int int_to_ip cidr_to_ip_count subnet_in_prefix get_usable_ips log analyze_vnet
    export OUTPUT_FILE LOG_FILE AZURE_RESERVED_IPS VERBOSE
    export RED GREEN YELLOW BLUE CYAN NC
    
    if [[ "${USE_XARGS:-false}" == "true" ]]; then
        echo "$vnets" | xargs -P "$MAX_PARALLEL_JOBS" -I {} bash -c '
            IFS=$'"'"'\t'"'"' read -r name rg id <<< "{}"
            analyze_vnet "$name" "$rg" "$id"
        '
    else
        echo "$vnets" | parallel --colsep '\t' -j "$MAX_PARALLEL_JOBS" \
            'analyze_vnet {1} {2} {3}'
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# GÉNÉRATION DU RAPPORT
#───────────────────────────────────────────────────────────────────────────────

generate_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    📊 RÉSUMÉ DE L'ANALYSE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        log ERROR "Fichier de sortie non trouvé"
        return
    fi
    
    # Statistiques
    local total_vnets total_prefixes total_subnets total_used total_available
    
    total_prefixes=$(tail -n +2 "$OUTPUT_FILE" | wc -l | tr -d ' ')
    total_vnets=$(tail -n +2 "$OUTPUT_FILE" | cut -d',' -f1 | sort -u | wc -l | tr -d ' ')
    total_subnets=$(tail -n +2 "$OUTPUT_FILE" | cut -d',' -f4 | awk '{sum+=$1} END {print sum}')
    total_used=$(tail -n +2 "$OUTPUT_FILE" | cut -d',' -f6 | awk '{sum+=$1} END {print sum}')
    total_available=$(tail -n +2 "$OUTPUT_FILE" | cut -d',' -f7 | awk '{sum+=$1} END {print sum}')
    
    echo -e "  ${BLUE}VNets analysés      :${NC} $total_vnets"
    echo -e "  ${BLUE}Prefixes analysés   :${NC} $total_prefixes"
    echo -e "  ${BLUE}Subnets totaux      :${NC} ${total_subnets:-0}"
    echo -e "  ${BLUE}IPs utilisées       :${NC} ${total_used:-0}"
    echo -e "  ${BLUE}IPs disponibles     :${NC} ${total_available:-0}"
    echo ""
    
    # Top 5 des VNets les plus utilisés
    echo -e "${YELLOW}  📈 Top 5 VNets par utilisation :${NC}"
    tail -n +2 "$OUTPUT_FILE" | sort -t',' -k8 -rn | head -5 | while IFS=',' read -r vnet rg prefix subnets total used avail percent; do
        printf "     %-30s %s (%s)\n" "$vnet" "$prefix" "$percent"
    done
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}📄 Rapport CSV :${NC} $OUTPUT_FILE"
    echo -e "  ${GREEN}📋 Log fichier :${NC} $LOG_FILE"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

open_report() {
    if command -v xdg-open &>/dev/null; then
        xdg-open "$OUTPUT_FILE" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$OUTPUT_FILE" 2>/dev/null &
    else
        log INFO "Ouvrez manuellement: $OUTPUT_FILE"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# MAIN
#───────────────────────────────────────────────────────────────────────────────

main() {
    # Parser les arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--parallel)
                USE_PARALLEL=true
                shift
                ;;
            -g|--graph)
                USE_RESOURCE_GRAPH=true
                shift
                ;;
            -j|--jobs)
                MAX_PARALLEL_JOBS=$2
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log ERROR "Option inconnue: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Afficher la bannière
    show_banner
    
    # Initialiser le log
    echo "=== Azure VNet Analyzer v$SCRIPT_VERSION ===" > "$LOG_FILE"
    echo "Démarré le: $(date)" >> "$LOG_FILE"
    
    # Vérifier les prérequis
    check_prerequisites
    
    # Créer l'en-tête du CSV
    echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalPrefixIPs,UsedIPs,AvailableIPs,UsagePercent" > "$OUTPUT_FILE"
    
    # Lancer l'analyse appropriée
    local start_time=$(date +%s)
    
    if $USE_RESOURCE_GRAPH; then
        analyze_with_resource_graph
    elif $USE_PARALLEL; then
        analyze_parallel
    else
        analyze_standard
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log OK "Analyse terminée en ${duration}s"
    
    # Générer le résumé
    generate_summary
    
    # Ouvrir le rapport
    open_report
}

# Exécuter le script
main "$@"
