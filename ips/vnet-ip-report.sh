# 🔧 Problème identifié : `set -e` + commandes avec exit code non-zéro

Le script quitte car certaines commandes retournent un code d'erreur (même si c'est normal). Voici la version corrigée :

```bash
#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET PREFIX ANALYZER – VERSION PRODUCTION v2.1
#═══════════════════════════════════════════════════════════════════════════════

# NE PAS utiliser set -e (cause des exits inattendus)
set -uo pipefail

#───────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
#───────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.1.0"
readonly OUTPUT_FILE="Azure_VNet_Report_$(date +%Y%m%d_%H%M%S).csv"
readonly LOG_FILE="azure_vnet_scan_$(date +%Y%m%d_%H%M%S).log"
readonly AZURE_RESERVED_IPS=5

# Couleurs
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Options
VERBOSE=false
USE_RESOURCE_GRAPH=false

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS UTILITAIRES
#───────────────────────────────────────────────────────────────────────────────

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        INFO)  [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}ℹ${NC}  $message" ;;
        OK)    echo -e "${GREEN}✅${NC} $message" ;;
        WARN)  echo -e "${YELLOW}⚠️${NC}  $message" ;;
        ERROR) echo -e "${RED}❌${NC} $message" >&2 ;;
        DEBUG) [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}🔍${NC} $message" ;;
    esac
}

show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           AZURE VNET PREFIX ANALYZER v2.1                     ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    -g, --graph         Utilise Azure Resource Graph (plus rapide)
    -v, --verbose       Mode verbeux
    -h, --help          Affiche cette aide
EOF
}

check_prerequisites() {
    log INFO "Vérification des prérequis..."
    
    if ! command -v az &>/dev/null; then
        log ERROR "Azure CLI non installé"
        exit 1
    fi
    
    if ! command -v jq &>/dev/null; then
        log ERROR "jq non installé"
        exit 1
    fi
    
    if ! az account show &>/dev/null; then
        log ERROR "Non connecté à Azure. Exécutez 'az login'"
        exit 1
    fi
    
    local account_name
    account_name=$(az account show --query "name" -o tsv 2>/dev/null || echo "Unknown")
    log OK "Connecté à Azure: $account_name"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTIONS DE CALCUL IP
#───────────────────────────────────────────────────────────────────────────────

ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

cidr_to_ip_count() {
    local cidr=$1
    local mask
    mask=${cidr#*/}
    echo $(( 2 ** (32 - mask) ))
}

subnet_in_prefix() {
    local prefix=$1
    local subnet=$2
    
    local prefix_ip prefix_mask subnet_ip subnet_mask
    prefix_ip=${prefix%/*}
    prefix_mask=${prefix#*/}
    subnet_ip=${subnet%/*}
    subnet_mask=${subnet#*/}
    
    # Le subnet doit avoir un masque >= au prefix
    if (( subnet_mask < prefix_mask )); then
        return 1
    fi
    
    local prefix_int subnet_int netmask
    prefix_int=$(ip_to_int "$prefix_ip")
    subnet_int=$(ip_to_int "$subnet_ip")
    netmask=$(( 0xFFFFFFFF << (32 - prefix_mask) ))
    
    if (( (prefix_int & netmask) == (subnet_int & netmask) )); then
        return 0
    else
        return 1
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTION PRINCIPALE D'ANALYSE
#───────────────────────────────────────────────────────────────────────────────

analyze_vnet() {
    local vnet_name=$1
    local resource_group=$2
    local vnet_id=$3
    
    log DEBUG "Analyse: $vnet_name (RG: $resource_group)"
    
    # Récupérer les détails du VNet
    local vnet_data
    vnet_data=$(az network vnet show --ids "$vnet_id" \
        --query "{prefixes:addressSpace.addressPrefixes, subnets:subnets[].{name:name, cidr:addressPrefix}}" \
        -o json 2>/dev/null)
    
    if [[ -z "$vnet_data" || "$vnet_data" == "null" ]]; then
        log WARN "Impossible de récupérer les détails de $vnet_name"
        return 0
    fi
    
    # Extraire les prefixes
    local prefixes_raw
    prefixes_raw=$(echo "$vnet_data" | jq -r '.prefixes[]? // empty' 2>/dev/null) || true
    
    if [[ -z "$prefixes_raw" ]]; then
        log WARN "Aucun prefix trouvé pour $vnet_name"
        return 0
    fi
    
    # Extraire les subnets JSON
    local subnets_json
    subnets_json=$(echo "$vnet_data" | jq -c '.subnets // []' 2>/dev/null) || subnets_json="[]"
    
    # Pour chaque prefix
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        
        log DEBUG "  Traitement prefix: $prefix"
        
        local prefix_mask total_prefix_ips
        prefix_mask=${prefix#*/}
        total_prefix_ips=$(cidr_to_ip_count "$prefix")
        
        local subnet_count=0
        local allocated_ips=0
        local used_ips=0
        
        # Récupérer la liste des subnets
        local subnet_list
        subnet_list=$(echo "$subnets_json" | jq -c '.[]? // empty' 2>/dev/null) || true
        
        if [[ -z "$subnet_list" ]]; then
            log DEBUG "  Aucun subnet dans ce VNet"
            # Écrire le résultat même sans subnets
            printf '%s,%s,%s,%s,%s,%s,%s,%s%%\n' \
                "$vnet_name" "$resource_group" "$prefix" \
                "0" "$total_prefix_ips" "0" "$total_prefix_ips" "0" >> "$OUTPUT_FILE"
            log OK "$vnet_name | $prefix → 0 subnets | Available: $total_prefix_ips"
            continue
        fi
        
        # Analyser chaque subnet
        while IFS= read -r subnet_entry; do
            [[ -z "$subnet_entry" ]] && continue
            
            local subnet_name subnet_cidr
            subnet_name=$(echo "$subnet_entry" | jq -r '.name // empty' 2>/dev/null) || continue
            subnet_cidr=$(echo "$subnet_entry" | jq -r '.cidr // empty' 2>/dev/null) || continue
            
            [[ -z "$subnet_name" || -z "$subnet_cidr" || "$subnet_cidr" == "null" ]] && continue
            
            log DEBUG "    Vérification subnet: $subnet_name ($subnet_cidr)"
            
            # Vérifier si le subnet appartient à ce prefix
            if subnet_in_prefix "$prefix" "$subnet_cidr"; then
                log DEBUG "    ✓ $subnet_name appartient à $prefix"
                
                ((subnet_count++)) || true
                
                # Calculer les IPs allouées
                local subnet_total
                subnet_total=$(cidr_to_ip_count "$subnet_cidr")
                allocated_ips=$((allocated_ips + subnet_total))
                
                # Récupérer les IPs utilisées via Azure
                local available_count
                available_count=$(az network vnet subnet list-available-ips \
                    -g "$resource_group" \
                    --vnet-name "$vnet_name" \
                    -n "$subnet_name" \
                    --query "length(@)" \
                    -o tsv 2>/dev/null) || available_count=0
                
                # S'assurer que c'est un nombre
                if ! [[ "$available_count" =~ ^[0-9]+$ ]]; then
                    available_count=0
                fi
                
                # IPs utilisables = Total - 5 réservées Azure
                local subnet_usable=$((subnet_total - AZURE_RESERVED_IPS))
                if (( subnet_usable < 0 )); then
                    subnet_usable=0
                fi
                
                # IPs utilisées dans ce subnet
                local subnet_used=$((subnet_usable - available_count))
                if (( subnet_used < 0 )); then
                    subnet_used=0
                fi
                
                used_ips=$((used_ips + subnet_used))
                
                log DEBUG "      Total: $subnet_total | Usable: $subnet_usable | Available: $available_count | Used: $subnet_used"
            fi
            
        done <<< "$subnet_list"
        
        # Calcul final
        local available_in_prefix usage_percent
        available_in_prefix=$((total_prefix_ips - allocated_ips))
        
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(( (allocated_ips * 100) / total_prefix_ips ))
        else
            usage_percent=0
        fi
        
        # Écrire dans le CSV
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
        
    done <<< "$prefixes_raw"
    
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
# ANALYSE STANDARD
#───────────────────────────────────────────────────────────────────────────────

analyze_standard() {
    log INFO "Récupération de la liste des VNets..."
    
    local vnets_json
    vnets_json=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o json 2>/dev/null)
    
    if [[ -z "$vnets_json" || "$vnets_json" == "[]" ]]; then
        log WARN "Aucun VNet trouvé"
        return 0
    fi
    
    local vnet_count
    vnet_count=$(echo "$vnets_json" | jq 'length' 2>/dev/null) || vnet_count=0
    
    log OK "Trouvé $vnet_count VNet(s) à analyser"
    echo ""
    
    local current=0
    
    # Boucle sur chaque VNet
    while IFS= read -r vnet_entry; do
        [[ -z "$vnet_entry" ]] && continue
        
        ((current++)) || true
        
        local vnet_name rg vnet_id
        vnet_name=$(echo "$vnet_entry" | jq -r '.name // empty') || continue
        rg=$(echo "$vnet_entry" | jq -r '.rg // empty') || continue
        vnet_id=$(echo "$vnet_entry" | jq -r '.id // empty') || continue
        
        if [[ -z "$vnet_name" || -z "$rg" || -z "$vnet_id" ]]; then
            log WARN "Données VNet incomplètes, ignoré"
            continue
        fi
        
        log INFO "[$current/$vnet_count] Analyse de $vnet_name..."
        
        # Appeler la fonction d'analyse
        analyze_vnet "$vnet_name" "$rg" "$vnet_id"
        
    done < <(echo "$vnets_json" | jq -c '.[]' 2>/dev/null)
    
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
#───────────────────────────────────────────────────────────────────────────────

generate_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    📊 RÉSUMÉ DE L'ANALYSE${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        log ERROR "Fichier non trouvé: $OUTPUT_FILE"
        return 0
    fi
    
    local line_count
    line_count=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
    
    if (( line_count <= 1 )); then
        log WARN "Aucune donnée dans le rapport"
        return 0
    fi
    
    # Stats
    local total_prefixes total_vnets
    total_prefixes=$((line_count - 1))
    total_vnets=$(tail -n +2 "$OUTPUT_FILE" | cut -d',' -f1 | sort -u | wc -l | tr -d ' ') || total_vnets=0
    
    echo ""
    echo -e "  ${BLUE}VNets analysés      :${NC} $total_vnets"
    echo -e "  ${BLUE}Prefixes analysés   :${NC} $total_prefixes"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}📄 Rapport :${NC} $OUTPUT_FILE"
    echo -e "  ${GREEN}📋 Log     :${NC} $LOG_FILE"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Afficher le contenu du CSV
    echo -e "${YELLOW}📋 Aperçu du rapport :${NC}"
    echo ""
    column -t -s',' "$OUTPUT_FILE" 2>/dev/null || cat "$OUTPUT_FILE"
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# MAIN
#───────────────────────────────────────────────────────────────────────────────

main() {
    # Parser les arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -g|--graph)
                USE_RESOURCE_GRAPH=true
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
    
    show_banner
    
    # Initialiser le log
    echo "=== Azure VNet Analyzer v$SCRIPT_VERSION ===" > "$LOG_FILE"
    echo "Démarré: $(date)" >> "$LOG_FILE"
    
    # Vérifications
    check_prerequisites
    
    # Créer l'en-tête CSV
    echo "VNetName,ResourceGroup,Prefix,SubnetCount,TotalIPs,UsedIPs,AvailableIPs,Usage" > "$OUTPUT_FILE"
    
    # Chrono
    local start_time end_time duration
    start_time=$(date +%s)
    
    # Lancer l'analyse
    analyze_standard
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    log OK "Analyse terminée en ${duration}s"
    
    # Résumé
    generate_summary
    
    # Ouvrir le fichier
    if command -v xdg-open &>/dev/null; then
        xdg-open "$OUTPUT_FILE" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$OUTPUT_FILE" 2>/dev/null &
    fi
}

# Exécuter
main "$@"
```

---

## 🔧 Corrections apportées

| Problème | Cause | Solution |
|----------|-------|----------|
| Script quitte après "3 VNets trouvés" | `set -e` + commande retournant non-zéro | Remplacé par `set -uo pipefail` uniquement |
| `((count++))` quitte si count=0 | Retourne 1 quand résultat = 0 | Ajouté `\|\| true` |
| `jq` échoue sur données vides | Pas de gestion null | Ajouté `// empty` et `// []` |
| Boucle `read` avec TSV | Problème de parsing | Changé pour JSON + `jq -c` |
| Variables non définies | `set -u` strict | Ajouté valeurs par défaut |

---

## 🧪 Test rapide

```bash
# Sauvegarder et rendre exécutable
chmod +x azure_vnet_analyzer.sh

# Test verbeux
./azure_vnet_analyzer.sh -v
```

---

## 📋 Sortie attendue

```
╔═══════════════════════════════════════════════════════════════╗
║           AZURE VNET PREFIX ANALYZER v2.1                     ║
╚═══════════════════════════════════════════════════════════════╝

✅ Connecté à Azure: My-Subscription
ℹ  Récupération de la liste des VNets...
✅ Trouvé 3 VNet(s) à analyser

ℹ  [1/3] Analyse de vnet-prod-001...
✅ vnet-prod-001 | 10.0.0.0/16 → 5 subnets | Used: 127 | Available: 64256 (2%)

ℹ  [2/3] Analyse de vnet-dev-001...
✅ vnet-dev-001 | 172.16.0.0/20 → 3 subnets | Used: 45 | Available: 3840 (6%)

ℹ  [3/3] Analyse de vnet-test-001...
✅ vnet-test-001 | 192.168.0.0/24 → 2 subnets | Used: 12 | Available: 200 (22%)

✅ Analyse terminée en 15s

═══════════════════════════════════════════════════════════════
                    📊 RÉSUMÉ DE L'ANALYSE
═══════════════════════════════════════════════════════════════

  VNets analysés      : 3
  Prefixes analysés   : 3

  📄 Rapport : Azure_VNet_Report_20250102_143052.csv
  📋 Log     : azure_vnet_scan_20250102_143052.log
═══════════════════════════════════════════════════════════════
```

Le script devrait maintenant s'exécuter **complètement** sans quitter prématurément ! 🎉
