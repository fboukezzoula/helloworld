Voici la version complète et optimisée du script.

### 🚀 Améliorations intégrées :
1.  **Robustesse Mathématique** : Correction de la conversion IP/Entier pour éviter les bugs sur certains shells.
2.  **Résilience (Retry Logic)** : Ajout d'une boucle de tentative pour les appels API `list-available-ips` (évite les échecs dus aux timeouts ou throttling Azure).
3.  **Enrichissement des données** : Ajout du **% d'utilisation** et du nombre d'**IPs Réservées Azure** dans le CSV.
4.  **Rapport de fin** : Génération d'un résumé global (Total IPs, % Global) dans le terminal.
5.  **Interface** : Ajout de couleurs et de logs plus clairs.

### Le Script

```bash
#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION OPTIMISÉE (v2.0)
#  Objectif : Calculer l'usage réel incluant les 5 IPs réservées Azure
#  Améliorations : Retry logic, % d'usage, rapport de synthèse, math robustes
#═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
OUTPUT_FILE="Azure_VNet_Usage_v2_$(date +%Y%m%d_%H%M%S).csv"
AZURE_RESERVED_COUNT=5
MAX_RETRIES=3

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ── FONCTIONS UTILITAIRES ─────────────────────────────────────────────────────

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Vérification des dépendances
check_dependencies() {
    for cmd in az jq awk; do
        if ! command -v $cmd >/dev/null 2>&1; then
            error "La commande '$cmd' est requise mais non installée."
            exit 1
        fi
    done
    
    if ! az account show >/dev/null 2>&1; then
        error "Vous n'êtes pas connecté à Azure. Veuillez lancer 'az login'."
        exit 1
    fi
}

# ── FONCTIONS MATHÉMATIQUES RÉSEAU ────────────────────────────────────────────

# Convertir CIDR (ex: /24) en nombre total d'IPs
cidr_to_count() {
    local mask=${1#*/}
    echo $(( 2 ** (32 - mask) ))
}

# Convertir IP (x.x.x.x) en entier 32 bits (Version robuste)
ip_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

# Vérifier si un subnet est inclus dans un prefix
subnet_in_prefix() {
    local p_cidr=$1 s_cidr=$2
    
    local p_ip=${p_cidr%/*} p_mask=${p_cidr#*/}
    local s_ip=${s_cidr%/*} s_mask=${s_cidr#*/}

    # Si le masque du subnet est plus petit que le prefix, impossible qu'il soit dedans
    (( s_mask >= p_mask )) || return 1

    local p_int s_int
    p_int=$(ip_to_int "$p_ip")
    s_int=$(ip_to_int "$s_ip")

    # Calcul du masque réseau
    local netmask=$(( 0xFFFFFFFF << (32 - p_mask) ))

    # Comparaison binaire
    (( (p_int & netmask) == (s_int & netmask) ))
}

# ── FONCTIONS API AZURE AVEC RETRY ────────────────────────────────────────────

# Récupérer les IPs disponibles avec tentative de reconnexion
get_available_ips() {
    local rg=$1 vnet=$2 subnet=$3
    local count=0
    local result=""

    while [[ $count -lt $MAX_RETRIES ]]; do
        # On utilise timeout pour éviter qu'un appel bloque indéfiniment
        result=$(timeout 20 az network vnet subnet list-available-ips \
            -g "$rg" --vnet-name "$vnet" -n "$subnet" \
            --query "length(@)" -o tsv 2>/dev/null)
        
        # Si succès et résultat non vide
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi

        ((count++))
        warn "  Timeout/Erreur API sur subnet '$subnet'. Essai $count/$MAX_RETRIES..."
        sleep 2
    done

    # Si échec total, on suppose 0 disponible par sécurité (ou on pourrait marquer une erreur)
    echo "0"
}

# ── TRAITEMENT PRINCIPAL ──────────────────────────────────────────────────────

main() {
    check_dependencies

    # En-tête CSV enrichi
    echo "VNet,ResourceGroup,Prefix,SubnetCount,ReservedAzureIPs,UsedIPs,AvailableIPs,UsagePercent" > "$OUTPUT_FILE"

    log "🔍 Récupération de la liste des VNets..."
    
    # On stocke la liste des VNets pour itérer
    local vnet_list
    vnet_list=$(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv)
    
    local total_vnets
    total_vnets=$(echo "$vnet_list" | wc -l)
    local current_vnet=0

    while IFS=$'\t' read -r vnet_name rg vnet_id; do
        ((current_vnet++))
        [[ -z "$vnet_name" ]] && continue
        
        echo -ne "📊 Analyse [$current_vnet/$total_vnets] : $vnet_name \r"

        # 1. Récupérer conf VNet (Prefixes + Subnets)
        local vnet_json
        vnet_json=$(az network vnet show --ids "$vnet_id" --query "{
            prefixes: addressSpace.addressPrefixes,
            subnets: subnets[].{name:name, cidr:addressPrefix}
        }" -o json 2>/dev/null)

        local prefixes subnets_json
        prefixes=$(echo "$vnet_json" | jq -r '.prefixes[]')
        subnets_json=$(echo "$vnet_json" | jq '.subnets')

        # 2. Pour chaque Prefix
        while IFS= read -r prefix; do
            [[ -z "$prefix" ]] && continue

            local total_prefix_ips
            total_prefix_ips=$(cidr_to_count "$prefix")
            
            local subnet_count=0
            local total_used_in_prefix=0
            local total_reserved_in_prefix=0

            # 3. Parcourir les subnets
            # On utilise une substitution de processus pour éviter le pipe qui créerait un sous-shell
            while IFS= read -r subnet_line; do
                [[ -z "$subnet_line" ]] && continue
                
                local s_name s_cidr
                s_name=$(echo "$subnet_line" | jq -r '.name')
                s_cidr=$(echo "$subnet_line" | jq -r '.cidr')

                # Si le subnet appartient à ce prefix
                if subnet_in_prefix "$prefix" "$s_cidr"; then
                    ((subnet_count++))
                    
                    local subnet_total
                    subnet_total=$(cidr_to_count "$s_cidr")

                    # Appel API (point critique)
                    local available_ips
                    available_ips=$(get_available_ips "$rg" "$vnet_name" "$s_name")

                    # Calculs :
                    # Used = Total Subnet - Available (API). 
                    # L'API retire déjà les 5 IPs réservées du "Available".
                    # Donc "Used" contient : Les IPs des VMs/NICs + Les 5 réservées.
                    local used_in_subnet=$((subnet_total - available_ips))
                    (( used_in_subnet < 0 )) && used_in_subnet=0

                    total_used_in_prefix=$((total_used_in_prefix + used_in_subnet))
                    total_reserved_in_prefix=$((total_reserved_in_prefix + AZURE_RESERVED_COUNT))
                fi
            done < <(echo "$subnets_json" | jq -c '.[]')

            # Calculs finaux pour le Prefix
            # Available = Total Prefix - (Ce qui est utilisé dans les subnets)
            # Note: Si le prefix n'est pas totalement "subneté", l'espace vide est considéré "available"
            local available_in_prefix=$((total_prefix_ips - total_used_in_prefix))
            
            # Pourcentage d'utilisation
            local usage_pct="0.00"
            if (( total_prefix_ips > 0 )); then
                usage_pct=$(awk "BEGIN {printf \"%.2f\", ($total_used_in_prefix / $total_prefix_ips) * 100}")
            fi

            # Écriture CSV
            printf '%s,%s,%s,%s,%s,%s,%s,%s%%\n' \
                "$vnet_name" "$rg" "$prefix" "$subnet_count" \
                "$total_reserved_in_prefix" "$total_used_in_prefix" \
                "$available_in_prefix" "$usage_pct" >> "$OUTPUT_FILE"

        done <<< "$prefixes"

    done <<< "$vnet_list"

    echo -e "\n"
    success "Analyse terminée !"
    generate_summary
}

# ── GÉNÉRATION DU RAPPORT DE SYNTHÈSE ─────────────────────────────────────────

generate_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "📈 SYNTHÈSE GLOBALE"
    echo "════════════════════════════════════════════════════════"
    
    if [[ ! -s "$OUTPUT_FILE" ]]; then
        error "Le fichier de sortie est vide."
        return
    fi

    awk -F, 'NR>1 {
        vnets[$1]=1
        total_cap+=$6+$7   # Used + Available = Total Capacity
        total_used+=$6
        total_avail+=$7
        total_reserved+=$5
    }
    END {
        if (total_cap > 0) {
            usage_global = (total_used / total_cap) * 100
        } else {
            usage_global = 0
        }
        
        printf "🔹 VNets analysés      : %d\n", length(vnets)
        printf "🔹 Capacité totale IPs : %d\n", total_cap
        printf "🔹 IPs Réservées (Azure): %d\n", total_reserved
        printf "🔹 IPs Utilisées (Réel): %d (dont réserves)\n", total_used
        printf "🔹 IPs Disponibles     : %d\n", total_avail
        printf "🔹 Taux d\047occupation    : %.2f%%\n", usage_global
        
        print ""
        if (usage_global > 80) 
            print "\033[0;31m⚠️  ATTENTION: L\047utilisation globale dépasse 80% !\033[0m"
        else
            print "\033[0;32m✅ L\047état du réseau semble sain.\033[0m"
    }' "$OUTPUT_FILE"

    echo "════════════════════════════════════════════════════════"
    echo "📄 Détails exportés dans : $OUTPUT_FILE"
}

# Lancer le script
main
```

### Comment l'utiliser

1.  Enregistrez le code dans un fichier, par exemple `az_vnet_audit.sh`.
2.  Rendez-le exécutable :
    ```bash
    chmod +x az_vnet_audit.sh
    ```
3.  Connectez-vous à Azure (si ce n'est pas déjà fait) :
    ```bash
    az login
    # Si vous avez plusieurs abonnements, sélectionnez le bon :
    # az account set --subscription "Nom-De-La-Souscription"
    ```
4.  Lancez le script :
    ```bash
    ./az_vnet_audit.sh
    ```

### Détails des colonnes CSV générées :

*   **VNet** : Nom du réseau virtuel.
*   **Prefix** : L'espace d'adressage analysé (ex: 10.0.0.0/16).
*   **SubnetCount** : Nombre de sous-réseaux détectés dans ce préfixe.
*   **ReservedAzureIPs** : Nombre total d'IPs réservées par Azure (5 * nombre de subnets).
*   **UsedIPs** : Total IPs non disponibles (inclus : VMs, Load Balancers, Private Endpoints **ET** les IPs réservées Azure).
*   **AvailableIPs** : IPs réellement libres pour déployer de nouvelles ressources.
*   **UsagePercent** : Taux d'occupation du préfixe.
