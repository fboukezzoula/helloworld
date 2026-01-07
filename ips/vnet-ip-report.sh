#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════════
#  AZURE VNET USAGE REPORT – VERSION FINALE CORRIGÉE
#  v2.2 - Avec toutes les corrections de syntaxe
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
DEBUG="${DEBUG:-false}"

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
CURRENT_SUB=$(az account show --query "[name, id]" -o tsv | head -1)
log "🔐 Connecté à: $CURRENT_SUB"

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
            warn "Retry $i/$retries pour $subnet..."
            sleep 2
        fi
    done
    
    warn "Impossible de récupérer les IPs disponibles pour $subnet (utilisation de 0)"
    echo "0"
}

#───────────────────────────────────────────────────────────────────────────────
# FONCTION DE TRAITEMENT D'UN VNET
#───────────────────────────────────────────────────────────────────────────────

process_vnet() {
    local vnet_name=$1
    local rg=$2
    local vnet_id=$3
    
    [[ -z "$vnet_name" ]] && return
    
    log "📊 Analyse de : $vnet_name ($rg)"

    # Récupérer les données du VNet
    local vnet_json
    vnet_json=$(az network vnet show --ids "$vnet_id" --query "{
        prefixes: addressSpace.addressPrefixes,
        subnets: subnets[].{name:name, cidr:addressPrefix}
    }" -o json 2>/dev/null)

    # Vérifier si le VNet existe et a des données
    if [[ -z "$vnet_json" ]] || [[ "$vnet_json" == "null" ]]; then
        warn "Impossible de récupérer les données pour $vnet_name"
        return
    fi

    # Extraire les tableaux
    local prefixes subnets_json
    prefixes=$(echo "$vnet_json" | jq -r '.prefixes[]' 2>/dev/null || echo "")
    subnets_json=$(echo "$vnet_json" | jq '.subnets' 2>/dev/null || echo "[]")

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
        while IFS= read -r subnet_line; do
            [[ -z "$subnet_line" ]] && continue
            
            local s_name s_cidr
            s_name=$(echo "$subnet_line" | jq -r '.name')
            s_cidr=$(echo "$subnet_line" | jq -r '.cidr')

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
        done < <(echo "$subnets_json" | jq -c '.[]' 2>/dev/null)

        # Calcul final
        local available_in_prefix=$((total_prefix_ips - total_used_in_prefix))
        
        # Calcul du pourcentage
        local usage_percent="0.00"
        if (( total_prefix_ips > 0 )); then
            usage_percent=$(awk "BEGIN {printf \"%.2f\", ($total_used_in_prefix / $total_prefix_ips) * 100}")
        fi

        # Écriture CSV
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

# Récupérer la liste des VNets
log "🔍 Récupération de la liste des VNets..."
VNET_COUNT=$(az network vnet list --query "length([])" -o tsv 2>/dev/null || echo "0")

if [[ "$VNET_COUNT" -eq 0 ]]; then
    warn "Aucun VNet trouvé dans la souscription"
    exit 0
fi

log "📝 $VNET_COUNT VNet(s) trouvé(s)"

# Export des fonctions
export -f cidr_to_count ip_to_int subnet_in_prefix get_available_ips process_vnet log warn error debug
export OUTPUT_FILE AZURE_RESERVED_COUNT RETRY_COUNT DEBUG RED GREEN YELLOW BLUE NC

# Traitement des VNets
if command -v parallel >/dev/null 2>&1 && [[ "${USE_PARALLEL:-false}" == "true" ]]; then
    log "⚡ Traitement parallèle activé ($PARALLEL_JOBS jobs)"
    
    az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv | \
    parallel --colsep '\t' -j $PARALLEL_JOBS --no-notice \
        "process_vnet {1} {2} {3}"
else
    log "🔄 Traitement séquentiel"
    
    while IFS=$'\t' read -r vnet_name rg vnet_id; do
        process_vnet "$vnet_name" "$rg" "$vnet_id"
    done < <(az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o tsv)
fi

#───────────────────────────────────────────────────────────────────────────────
# GÉNÉRATION DU RAPPORT DE SYNTHÈSE
#───────────────────────────────────────────────────────────────────────────────

generate_summary() {
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
        
        printf "💾 UTILISATION DES IPs\n"
        printf "├─ IPs totales       : %d\n", total_ips
        printf "├─ IPs utilisées     : %d (%.2f%%)\n", total_used, usage_pct
        printf "│  ├─ Réservées Azure: %d\n", total_reserved
        printf "│  └─ Réellement utilisées: %d (%.2f%%)\n", real_used, real_usage_pct
        printf "└─ IPs disponibles   : %d\n\n", total_available
        
        if (length(critical_usage) > 0) {
            print "🔴 ALERTES CRITIQUES (>90%)"
            for (i in critical_usage) print "   └─ " critical_usage[i]
            print ""
        }
        
        if (length(high_usage) > 0 && length(critical_usage) != length(high_usage)) {
            print "🟠 ALERTES HAUTES (>80%)"
            for (i in high_usage) {
                if (!(i in critical_usage)) print "   └─ " high_usage[i]
            }
            print ""
        }
        
        print "💡 RECOMMANDATIONS"
        if (usage_pct > 85) {
            print "   ⚠️  Utilisation globale élevée - Planifier une extension"
        } else if (usage_pct > 70) {
            print "   ℹ️  Utilisation normale - Surveiller la croissance"
        } else {
            print "   ✅ Capacité suffisante disponible"
        }
    }' "$OUTPUT_FILE"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

#───────────────────────────────────────────────────────────────────────────────
# EXPORT EN JSON (OPTIONNEL)
#───────────────────────────────────────────────────────────────────────────────

export_to_json() {
    log "📄 Génération du fichier JSON..."
    
    {
        echo "{"
        echo "  \"metadata\": {"
        echo "    \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "    \"subscription\": \"$CURRENT_SUB\","
        echo "    \"azure_reserved_ips_per_subnet\": $AZURE_RESERVED_COUNT"
        echo "  },"
        echo "  \"vnets\": ["
        
        awk -F, 'NR>1 {
            if (NR>2) printf ",\n"
            printf "    {\n"
            printf "      \"vnet\": \"%s\",\n", $1
            printf "      \"resourceGroup\": \"%s\",\n", $2
            printf "      \"prefix\": \"%s\",\n", $3
            printf "      \"subnetCount\": %s,\n", $4
            printf "      \"usedIPs\": %s,\n", $5
            printf "      \"availableIPs\": %s,\n", $6
            printf "      \"usagePercent\": %s,\n", $7
            printf "      \"reservedIPs\": %s\n", $8
            printf "    }"
        }' "$OUTPUT_FILE"
        
        echo ""
        echo "  ],"
        echo "  \"summary\": {"
        
        awk -F, 'NR>1 {
            total_used+=$5
            total_available+=$6
            total_reserved+=$8
            vnets[$1]=1
        }
        END {
            total_ips = total_used + total_available
            usage_pct = total_ips > 0 ? (total_used / total_ips) * 100 : 0
            
            printf "    \"totalVNets\": %d,\n", length(vnets)
            printf "    \"totalIPs\": %d,\n", total_ips
            printf "    \"usedIPs\": %d,\n", total_used
            printf "    \"availableIPs\": %d,\n", total_available
            printf "    \"reservedIPs\": %d,\n", total_reserved
            printf "    \"globalUsagePercent\": %.2f\n", usage_pct
        }' "$OUTPUT_FILE"
        
        echo "  }"
        echo "}"
    } > "$JSON_FILE"
    
    if jq empty "$JSON_FILE" 2>/dev/null; then
        log "✅ Fichier JSON valide créé: $JSON_FILE"
    else
        error "Le fichier JSON généré n'est pas valide"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# EXPORT HTML (OPTIONNEL)
#───────────────────────────────────────────────────────────────────────────────

export_to_html() {
    log "📄 Génération du rapport HTML..."
    
    cat > "$HTML_FILE" <<'HTML_HEADER'
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Azure VNet Usage Report</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            min-height: 100vh;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #0078D4 0%, #005A9E 100%);
            color: white;
            padding: 30px;
        }
        .header h1 {
            font-size: 2em;
            margin-bottom: 10px;
        }
        .header .date {
            opacity: 0.9;
            font-size: 0.9em;
        }
        .content {
            padding: 30px;
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        .stat-card h3 {
            font-size: 0.9em;
            opacity: 0.9;
            margin-bottom: 5px;
        }
        .stat-card .value {
            font-size: 2em;
            font-weight: bold;
        }
        .filter-bar {
            margin-bottom: 20px;
            padding: 15px;
            background: #f5f5f5;
            border-radius: 5px;
        }
        .filter-bar input {
            padding: 8px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            width: 300px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
        }
        th {
            background: #f5f5f5;
            padding: 12px;
            text-align: left;
            font-weight: 600;
            border-bottom: 2px solid #ddd;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #eee;
        }
        tr:hover {
            background: #f9f9f9;
        }
        .usage-bar {
            width: 100px;
            height: 20px;
            background: #e0e0e0;
            border-radius: 10px;
            overflow: hidden;
            position: relative;
            display: inline-block;
        }
        .usage-fill {
            height: 100%;
            background: linear-gradient(90deg, #4CAF50, #8BC34A);
            transition: width 0.3s ease;
        }
        .usage-fill.warning { background: linear-gradient(90deg, #FF9800, #FFB74D); }
        .usage-fill.danger { background: linear-gradient(90deg, #f44336, #ef5350); }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌐 Azure VNet Usage Report</h1>
            <div class="date">Generated on: <span id="genDate"></span></div>
        </div>
        <div class="content">
            <div class="stats-grid" id="statsGrid"></div>
            <div class="filter-bar">
                <input type="text" id="searchInput" placeholder="🔍 Search VNet, Resource Group or Prefix..." onkeyup="filterTable()">
            </div>
            <table id="dataTable">
                <thead>
                    <tr>
                        <th>VNet</th>
                        <th>Resource Group</th>
                        <th>Prefix</th>
                        <th>Subnets</th>
                        <th>Used IPs</th>
                        <th>Available IPs</th>
                        <th>Usage</th>
                        <th>Reserved IPs</th>
                    </tr>
                </thead>
                <tbody id="tableBody">
                </tbody>
            </table>
        </div>
    </div>
    
    <script>
        const data = [
HTML_HEADER

    # Ajouter les données CSV converties en JavaScript
    awk -F, 'NR>1 {
        if (NR>2) printf ",\n"
        printf "            {vnet:\"%s\", rg:\"%s\", prefix:\"%s\", subnets:%s, used:%s, available:%s, usage:%s, reserved:%s}", 
            $1, $2, $3, $4, $5, $6, $7, $8
    }' "$OUTPUT_FILE" >> "$HTML_FILE"

    cat >> "$HTML_FILE" <<'HTML_FOOTER'
        ];
        
        // Populate table
        const tbody = document.getElementById('tableBody');
        data.forEach(row => {
            const tr = document.createElement('tr');
            
            // Determine usage level
            let usageClass = '';
            if (row.usage > 90) usageClass = 'danger';
            else if (row.usage > 80) usageClass = 'warning';
            
            tr.innerHTML = `
                <td>${row.vnet}</td>
                <td>${row.rg}</td>
                <td><code>${row.prefix}</code></td>
                <td>${row.subnets}</td>
                <td>${row.used.toLocaleString()}</td>
                <td>${row.available.toLocaleString()}</td>
                <td>
                    <div style="display: flex; align-items: center; gap: 10px;">
                        <div class="usage-bar">
                            <div class="usage-fill ${usageClass}" style="width: ${row.usage}%"></div>
                        </div>
                        <span>${row.usage}%</span>
                    </div>
                </td>
                <td>${row.reserved}</td>
            `;
            tbody.appendChild(tr);
        });
        
        // Calculate stats
        const stats = {
            vnets: new Set(data.map(d => d.vnet)).size,
            totalUsed: data.reduce((sum, d) => sum + d.used, 0),
            totalAvailable: data.reduce((sum, d) => sum + d.available, 0),
            totalReserved: data.reduce((sum, d) => sum + d.reserved, 0)
        };
        stats.totalIPs = stats.totalUsed + stats.totalAvailable;
        stats.usagePercent = ((stats.totalUsed / stats.totalIPs) * 100).toFixed(2);
        
        // Display stats
        document.getElementById('statsGrid').innerHTML = `
            <div class="stat-card" style="background: linear-gradient(135deg, #0078D4, #005A9E);">
                <h3>Total VNets</h3>
                <div class="value">${stats.vnets}</div>
            </div>
            <div class="stat-card" style="background: linear-gradient(135deg, #4CAF50, #8BC34A);">
                <h3>Available IPs</h3>
                <div class="value">${stats.totalAvailable.toLocaleString()}</div>
            </div>
            <div class="stat-card" style="background: linear-gradient(135deg, #FF9800, #FFB74D);">
                <h3>Used IPs</h3>
                <div class="value">${stats.totalUsed.toLocaleString()}</div>
            </div>
            <div class="stat-card" style="background: linear-gradient(135deg, #9C27B0, #BA68C8);">
                <h3>Global Usage</h3>
                <div class="value">${stats.usagePercent}%</div>
            </div>
        `;
        
        // Set generation date
        document.getElementById('genDate').textContent = new Date().toLocaleString();
        
        // Filter function
        function filterTable() {
            const input = document.getElementById('searchInput').value.toLowerCase();
            const rows = document.querySelectorAll('#tableBody tr');
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                row.style.display = text.includes(input) ? '' : 'none';
            });
        }
    </script>
</body>
</html>
HTML_FOOTER

    log "✅ Rapport HTML créé: $HTML_FILE"
}

#───────────────────────────────────────────────────────────────────────────────
# FINALISATION
#───────────────────────────────────────────────────────────────────────────────

# Appeler la fonction de résumé
generate_summary

# Export JSON si demandé
if [[ "$EXPORT_JSON" == "true" ]]; then
    export_to_json
fi

# Export HTML si demandé
if [[ "$EXPORT_HTML" == "true" ]]; then
    export_to_html
fi

# Affichage final
echo ""
echo "✅ Analyse terminée avec succès!"
echo ""
echo "📁 Fichiers générés:"
echo "   📄 CSV: $OUTPUT_FILE"
[[ "$EXPORT_JSON" == "true" ]] && echo "   📄 JSON: $JSON_FILE"
[[ "$EXPORT_HTML" == "true" ]] && echo "   📄 HTML: $HTML_FILE"
echo ""

# Proposer d'ouvrir le rapport HTML (Linux/Mac)
if [[ "$EXPORT_HTML" == "true" ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
        # Linux
        read -p "Voulez-vous ouvrir le rapport HTML ? (o/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Oo]$ ]]; then
            xdg-open "$HTML_FILE"
        fi
    elif command -v open >/dev/null 2>&1; then
        # macOS
        read -p "Voulez-vous ouvrir le rapport HTML ? (o/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Oo]$ ]]; then
            open "$HTML_FILE"
        fi
    fi
fi

exit 0
