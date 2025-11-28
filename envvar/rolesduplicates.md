# Avant de lancer le script :
## 1. Rendre le script exécutable

```bash
chmod +x check_duplicate_role_versions.sh
```

## 2. Exporter les variables du SPN

```bash
export AZURE_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export AZURE_CLIENT_SECRET="votre-secret"
export AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## 3. Vérifier que jq est installé

```bash
jq --version || sudo apt-get install jq
```


# Exécution :

```bash
# Analyse simple
./check_duplicate_role_versions.sh BU1

# Avec export CSV
./check_duplicate_role_versions.sh BU1 --report
```

# Code de retour :

Code	--- Signification
- 0	--- Aucun doublon détecté ✅
- 1	--- Doublons détectés ⚠️

```bash
#!/bin/bash

#===============================================================================
# Script: check_duplicate_role_versions.sh
# Description: Détecte les rôles custom avec versions multiples assignés au
#              groupe powerusers d'une souscription (1 groupe par souscription)
# Usage: ./check_duplicate_role_versions.sh <BU_NAME> [--report]
# Example: ./check_duplicate_role_versions.sh BU1
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION - Variables d'environnement requises pour le SPN
#-------------------------------------------------------------------------------
# - AZURE_CLIENT_ID       : Application (client) ID du SPN
# - AZURE_CLIENT_SECRET   : Secret du SPN
# - AZURE_TENANT_ID       : Tenant ID

#-------------------------------------------------------------------------------
# MAPPING BU -> Management Group Root
#-------------------------------------------------------------------------------
declare -A MG_ROOT_MAPPING=(
    ["BU1"]="MG-BU1-ROOT"
    ["BU2"]="MG-BU2-ROOT"
)

#-------------------------------------------------------------------------------
# COULEURS POUR L'AFFICHAGE
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

#-------------------------------------------------------------------------------
# FONCTIONS UTILITAIRES
#-------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_finding() {
    echo -e "${CYAN}[FINDING]${NC} $1"
}

log_subscription() {
    echo -e "${MAGENTA}[SUBSCRIPTION]${NC} $1"
}

print_separator() {
    echo "=========================================================================="
}

print_sub_separator() {
    echo "  ------------------------------------------------------------------------"
}

#-------------------------------------------------------------------------------
# VALIDATION DES PRÉREQUIS
#-------------------------------------------------------------------------------
check_prerequisites() {
    log_info "Vérification des prérequis..."
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI n'est pas installé."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq n'est pas installé (apt-get install jq)."
        exit 1
    fi

    if [[ -z "${AZURE_CLIENT_ID:-}" ]] || \
       [[ -z "${AZURE_CLIENT_SECRET:-}" ]] || \
       [[ -z "${AZURE_TENANT_ID:-}" ]]; then
        log_error "Variables d'environnement manquantes: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID"
        exit 1
    fi

    log_success "Tous les prérequis sont satisfaits."
}

#-------------------------------------------------------------------------------
# CONNEXION AZURE AVEC SPN
#-------------------------------------------------------------------------------
azure_login() {
    log_info "Connexion à Azure avec le Service Principal..."
    
    az login --service-principal \
        --username "${AZURE_CLIENT_ID}" \
        --password "${AZURE_CLIENT_SECRET}" \
        --tenant "${AZURE_TENANT_ID}" \
        --output none 2>/dev/null

    if [[ $? -eq 0 ]]; then
        log_success "Connexion Azure réussie."
    else
        log_error "Échec de la connexion Azure."
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# RECHERCHER TOUS LES GROUPES CORRESPONDANT AU PATTERN
#-------------------------------------------------------------------------------
find_groups_by_pattern() {
    local bu_name="$1"
    local bu_lower=$(echo "${bu_name}" | tr '[:upper:]' '[:lower:]')
    local group_prefix="atm-grp-${bu_lower}-powerusers-"
    
    log_info "Recherche des groupes EntraID avec le pattern: ${group_prefix}*"
    
    local groups_json
    groups_json=$(az ad group list \
        --query "[?starts_with(displayName, '${group_prefix}')].{displayName:displayName, id:id}" \
        --output json 2>/dev/null)
    
    if [[ -z "${groups_json}" ]] || [[ "${groups_json}" == "[]" ]]; then
        groups_json=$(az rest \
            --method GET \
            --uri "https://graph.microsoft.com/v1.0/groups?\$filter=startswith(displayName,'${group_prefix}')&\$select=id,displayName" \
            --query "value" \
            --output json 2>/dev/null) || true
    fi
    
    if [[ -z "${groups_json}" ]] || [[ "${groups_json}" == "[]" ]]; then
        log_warning "Aucun groupe trouvé avec le pattern: ${group_prefix}*"
        echo "[]"
        return
    fi
    
    local group_count=$(echo "${groups_json}" | jq 'length')
    log_success "Nombre de groupes powerusers trouvés: ${group_count}"
    
    echo "${groups_json}"
}

#-------------------------------------------------------------------------------
# RÉCUPÉRER TOUTES LES SOUSCRIPTIONS D'UN MANAGEMENT GROUP (RÉCURSIF)
#-------------------------------------------------------------------------------
get_subscriptions_recursive() {
    local mg_name="$1"
    
    log_info "Récupération récursive des souscriptions du MG: ${mg_name}..."
    
    local descendants
    descendants=$(az rest \
        --method GET \
        --uri "https://management.azure.com/providers/Microsoft.Management/managementGroups/${mg_name}/descendants?api-version=2020-05-01" \
        2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "${descendants}" ]]; then
        log_error "Impossible de récupérer les descendants du MG: ${mg_name}"
        exit 1
    fi
    
    echo "${descendants}" | jq -r '.value[] | select(.type | test("subscriptions$"; "i")) | .name' 2>/dev/null
}

#-------------------------------------------------------------------------------
# RÉCUPÉRER LES ROLE ASSIGNMENTS POUR LE GROUPE POWERUSERS D'UNE SOUSCRIPTION
# Cherche parmi tous les groupes celui qui a des assignments sur cette souscription
#-------------------------------------------------------------------------------
get_role_assignments_for_subscription() {
    local subscription_id="$1"
    local groups_json="$2"
    
    az account set --subscription "${subscription_id}" 2>/dev/null || return
    
    local result_group_name=""
    local result_assignments="[]"
    
    # Chercher le groupe qui a des assignments sur cette souscription
    while IFS= read -r group_line; do
        [[ -z "${group_line}" ]] && continue
        
        local group_id=$(echo "${group_line}" | jq -r '.id')
        local group_name=$(echo "${group_line}" | jq -r '.displayName')
        
        [[ -z "${group_id}" ]] || [[ "${group_id}" == "null" ]] && continue
        
        local assignments
        assignments=$(az role assignment list \
            --assignee "${group_id}" \
            --subscription "${subscription_id}" \
            --query "[].{roleDefinitionName:roleDefinitionName, scope:scope}" \
            --output json 2>/dev/null) || continue
        
        if [[ -n "${assignments}" ]] && [[ "${assignments}" != "[]" ]]; then
            result_group_name="${group_name}"
            result_assignments="${assignments}"
            break  # Un seul groupe par souscription, on s'arrête
        fi
        
    done < <(echo "${groups_json}" | jq -c '.[]')
    
    # Retourner le résultat au format JSON
    echo "{\"groupName\": \"${result_group_name}\", \"assignments\": ${result_assignments}}"
}

#-------------------------------------------------------------------------------
# EXTRAIRE LE NOM DE BASE ET LA VERSION D'UN RÔLE
#-------------------------------------------------------------------------------
extract_role_base_and_version() {
    local role_name="$1"
    local base_name=""
    local version=""
    
    if [[ "${role_name}" =~ ^(.+)(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    elif [[ "${role_name}" =~ ^(.+)-(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    elif [[ "${role_name}" =~ ^(.+)_(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    elif [[ "${role_name}" =~ ^(.+)-([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="v${BASH_REMATCH[2]}"
    elif [[ "${role_name}" =~ ^(.+)_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="v${BASH_REMATCH[2]}"
    else
        base_name="${role_name}"
        version="no_version"
    fi
    
    base_name="${base_name%-}"
    base_name="${base_name%_}"
    
    echo "${base_name}|${version}"
}

#-------------------------------------------------------------------------------
# ANALYSER LES DOUBLONS POUR UNE SOUSCRIPTION DONNÉE
#-------------------------------------------------------------------------------
analyze_subscription_duplicates() {
    local subscription_name="$1"
    local group_name="$2"
    local assignments_json="$3"
    
    declare -A role_versions      # base_name -> versions
    declare -A role_full_names    # base_name|version -> full role name
    
    local duplicates_found=0
    
    # Parser les assignments
    while IFS= read -r role_name; do
        [[ -z "${role_name}" ]] || [[ "${role_name}" == "null" ]] && continue
        
        local parsed=$(extract_role_base_and_version "${role_name}")
        local base_name=$(echo "${parsed}" | cut -d'|' -f1)
        local version=$(echo "${parsed}" | cut -d'|' -f2)
        
        [[ "${version}" == "no_version" ]] && continue
        
        # Stocker le nom complet
        role_full_names["${base_name}|${version}"]="${role_name}"
        
        # Ajouter la version
        if [[ -z "${role_versions[${base_name}]:-}" ]]; then
            role_versions["${base_name}"]="${version}"
        else
            if [[ ! "${role_versions[${base_name}]}" =~ (^|,)${version}(,|$) ]]; then
                role_versions["${base_name}"]="${role_versions[${base_name}]},${version}"
            fi
        fi
        
    done < <(echo "${assignments_json}" | jq -r '.[].roleDefinitionName')
    
    # Détecter les doublons
    declare -a duplicates_list=()
    
    for base_name in "${!role_versions[@]}"; do
        local versions="${role_versions[${base_name}]}"
        local version_count=$(echo "${versions}" | tr ',' '\n' | wc -l)
        
        if [[ ${version_count} -gt 1 ]]; then
            ((duplicates_found++))
            
            local formatted_versions=$(echo "${versions}" | tr ',' '\n' | sort -V | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            
            # Collecter les noms complets des rôles
            local role_names=""
            for version in $(echo "${versions}" | tr ',' '\n' | sort -V); do
                local key="${base_name}|${version}"
                local full_name="${role_full_names[${key}]:-${base_name}${version}}"
                role_names="${role_names}|${full_name}"
            done
            role_names="${role_names#|}"
            
            duplicates_list+=("${base_name}::${formatted_versions}::${role_names}")
        fi
    done
    
    # Afficher les résultats si des doublons ont été trouvés
    if [[ ${duplicates_found} -gt 0 ]]; then
        echo ""
        log_subscription "${subscription_name}"
        echo -e "  Groupe: ${YELLOW}${group_name}${NC}"
        print_sub_separator
        
        for entry in "${duplicates_list[@]}"; do
            local base_name=$(echo "${entry}" | cut -d'::' -f1)
            local versions=$(echo "${entry}" | cut -d'::' -f2)
            local role_names=$(echo "${entry}" | cut -d'::' -f3)
            
            log_finding "Duplicate role \"${base_name}\": ${YELLOW}${versions}${NC}"
            echo "           Rôles assignés:"
            
            IFS='|' read -ra names <<< "${role_names}"
            for name in "${names[@]}"; do
                [[ -z "${name}" ]] && continue
                echo "             • ${name}"
            done
        done
    fi
    
    echo "${duplicates_found}"
}

#-------------------------------------------------------------------------------
# GÉNÉRER UN RAPPORT CSV
#-------------------------------------------------------------------------------
generate_csv_report() {
    local -n roles_array=$1
    local output_file="$2"
    
    echo "Subscription,GroupName,RoleName,BaseRoleName,Version,IsDuplicate" > "${output_file}"
    
    # Identifier les doublons
    declare -A duplicate_keys
    
    for entry in "${roles_array[@]}"; do
        local subscription=$(echo "${entry}" | cut -d'|' -f1)
        local group_name=$(echo "${entry}" | cut -d'|' -f2)
        local role_name=$(echo "${entry}" | cut -d'|' -f3)
        
        local parsed=$(extract_role_base_and_version "${role_name}")
        local base_name=$(echo "${parsed}" | cut -d'|' -f1)
        local version=$(echo "${parsed}" | cut -d'|' -f2)
        
        [[ "${version}" == "no_version" ]] && continue
        
        local key="${subscription}|${base_name}"
        
        if [[ -z "${duplicate_keys[${key}]:-}" ]]; then
            duplicate_keys["${key}"]="${version}"
        else
            if [[ ! "${duplicate_keys[${key}]}" =~ (^|,)${version}(,|$) ]]; then
                duplicate_keys["${key}"]="${duplicate_keys[${key}]},${version}"
            fi
        fi
    done
    
    declare -A is_duplicate
    for key in "${!duplicate_keys[@]}"; do
        local versions="${duplicate_keys[${key}]}"
        local version_count=$(echo "${versions}" | tr ',' '\n' | wc -l)
        [[ ${version_count} -gt 1 ]] && is_duplicate["${key}"]="true"
    done
    
    # Écrire le CSV
    for entry in "${roles_array[@]}"; do
        local subscription=$(echo "${entry}" | cut -d'|' -f1)
        local group_name=$(echo "${entry}" | cut -d'|' -f2)
        local role_name=$(echo "${entry}" | cut -d'|' -f3)
        
        local parsed=$(extract_role_base_and_version "${role_name}")
        local base_name=$(echo "${parsed}" | cut -d'|' -f1)
        local version=$(echo "${parsed}" | cut -d'|' -f2)
        
        local key="${subscription}|${base_name}"
        local dup_flag="No"
        [[ -n "${is_duplicate[${key}]:-}" ]] && dup_flag="Yes"
        
        echo "\"${subscription}\",\"${group_name}\",\"${role_name}\",\"${base_name}\",\"${version}\",\"${dup_flag}\"" >> "${output_file}"
    done
    
    log_success "Rapport CSV généré: ${output_file}"
}

#-------------------------------------------------------------------------------
# FONCTION PRINCIPALE
#-------------------------------------------------------------------------------
main() {
    local bu_name="${1:-}"
    local generate_report=false
    
    if [[ -z "${bu_name}" ]]; then
        log_error "Usage: $0 <BU_NAME> [--report]"
        log_error "Exemple: $0 BU1"
        exit 1
    fi
    
    [[ "${2:-}" == "--report" ]] && generate_report=true
    
    bu_name=$(echo "${bu_name}" | tr '[:lower:]' '[:upper:]')
    
    if [[ -z "${MG_ROOT_MAPPING[${bu_name}]:-}" ]]; then
        log_error "BU inconnue: ${bu_name}. Disponibles: ${!MG_ROOT_MAPPING[*]}"
        exit 1
    fi
    
    local mg_root="${MG_ROOT_MAPPING[${bu_name}]}"
    local bu_lower=$(echo "${bu_name}" | tr '[:upper:]' '[:lower:]')
    
    echo ""
    print_separator
    echo -e "${BOLD}  Analyse des rôles dupliqués pour ${bu_name}${NC}"
    print_separator
    echo ""
    echo "  Management Group : ${mg_root}"
    echo "  Pattern groupes  : atm-grp-${bu_lower}-powerusers-*"
    echo ""
    print_separator
    echo ""
    
    check_prerequisites
    azure_login
    
    # Rechercher les groupes
    local groups_json
    groups_json=$(find_groups_by_pattern "${bu_name}")
    
    local group_count=$(echo "${groups_json}" | jq 'length')
    if [[ ${group_count} -eq 0 ]]; then
        log_error "Aucun groupe powerusers trouvé pour ${bu_name}"
        exit 1
    fi
    
    # Récupérer les souscriptions
    local subscription_ids
    subscription_ids=$(get_subscriptions_recursive "${mg_root}")
    
    if [[ -z "${subscription_ids}" ]]; then
        log_warning "Aucune souscription trouvée dans le MG: ${mg_root}"
        exit 0
    fi
    
    local sub_count=$(echo "${subscription_ids}" | grep -c '^' || echo 0)
    log_success "Nombre de souscriptions trouvées: ${sub_count}"
    
    # Données pour le rapport
    declare -a all_roles=()
    
    # Compteurs
    local total_duplicates=0
    local subscriptions_with_duplicates=0
    local subscriptions_with_group=0
    local processed=0
    
    echo ""
    print_separator
    echo -e "${BOLD}                    ANALYSE PAR SOUSCRIPTION${NC}"
    print_separator
    
    while IFS= read -r subscription_id; do
        [[ -z "${subscription_id}" ]] && continue
        
        ((processed++))
        
        local sub_name
        sub_name=$(az account show --subscription "${subscription_id}" --query "name" -o tsv 2>/dev/null || echo "${subscription_id}")
        
        printf "\r  Analyse: [%3d/%3d] %-50s" "${processed}" "${sub_count}" "${sub_name:0:50}"
        
        # Récupérer les assignments
        local result
        result=$(get_role_assignments_for_subscription "${subscription_id}" "${groups_json}")
        
        local group_name=$(echo "${result}" | jq -r '.groupName')
        local assignments=$(echo "${result}" | jq '.assignments')
        
        # Si pas de groupe trouvé pour cette souscription, continuer
        if [[ -z "${group_name}" ]] || [[ "${group_name}" == "null" ]] || [[ "${group_name}" == "" ]]; then
            continue
        fi
        
        ((subscriptions_with_group++))
        
        local assignment_count=$(echo "${assignments}" | jq 'length' 2>/dev/null || echo 0)
        
        if [[ ${assignment_count} -gt 0 ]]; then
            # Stocker pour le rapport
            while IFS= read -r role_name; do
                [[ -z "${role_name}" ]] || [[ "${role_name}" == "null" ]] && continue
                all_roles+=("${sub_name}|${group_name}|${role_name}")
            done < <(echo "${assignments}" | jq -r '.[].roleDefinitionName')
            
            # Analyser les doublons
            local dup_count
            dup_count=$(analyze_subscription_duplicates "${sub_name}" "${group_name}" "${assignments}")
            
            if [[ ${dup_count} -gt 0 ]]; then
                ((total_duplicates += dup_count))
                ((subscriptions_with_duplicates++))
            fi
        fi
        
    done <<< "${subscription_ids}"
    
    printf "\r%-80s\r" " "
    
    # Résumé
    echo ""
    print_separator
    echo -e "${BOLD}                        RÉSUMÉ${NC}"
    print_separator
    echo ""
    echo "  Souscriptions analysées            : ${sub_count}"
    echo "  Souscriptions avec groupe assigné  : ${subscriptions_with_group}"
    echo "  Role assignments analysés          : ${#all_roles[@]}"
    echo ""
    
    if [[ ${total_duplicates} -gt 0 ]]; then
        echo -e "  ${RED}Rôles dupliqués détectés            : ${total_duplicates}${NC}"
        echo -e "  ${RED}Souscriptions avec doublons         : ${subscriptions_with_duplicates}${NC}"
    else
        echo -e "  ${GREEN}Rôles dupliqués détectés            : 0${NC}"
        log_success "Aucune incohérence de version détectée!"
    fi
    
    echo ""
    
    if [[ "${generate_report}" == "true" ]] && [[ ${#all_roles[@]} -gt 0 ]]; then
        local report_file="role_duplicates_${bu_name}_$(date +%Y%m%d_%H%M%S).csv"
        generate_csv_report all_roles "${report_file}"
    fi
    
    log_info "Déconnexion d'Azure..."
    az logout 2>/dev/null || true
    
    echo ""
    log_success "Analyse terminée."
    echo ""
    
    [[ ${total_duplicates} -gt 0 ]] && exit 1
    exit 0
}

#-------------------------------------------------------------------------------
# EXÉCUTION
#-------------------------------------------------------------------------------
main "$@"
```


# Sortie

```text
==========================================================================
  Analyse des rôles dupliqués pour BU1
==========================================================================

  Management Group : MG-BU1-ROOT
  Pattern groupes  : atm-grp-bu1-powerusers-*

==========================================================================

[INFO] Vérification des prérequis...
[SUCCESS] Tous les prérequis sont satisfaits.
[INFO] Connexion à Azure avec le Service Principal...
[SUCCESS] Connexion Azure réussie.
[INFO] Recherche des groupes EntraID avec le pattern: atm-grp-bu1-powerusers-*
[SUCCESS] Nombre de groupes powerusers trouvés: 12
[SUCCESS] Nombre de souscriptions trouvées: 12

==========================================================================
                    ANALYSE PAR SOUSCRIPTION
==========================================================================

[SUBSCRIPTION] subscriptionname1-bu1-dev
  Groupe: atm-grp-bu1-powerusers-app-finance
  ------------------------------------------------------------------------
[FINDING] Duplicate role "CUSTOM-ROLE-SQL": v1.0, v1.5
           Rôles assignés:
             • CUSTOM-ROLE-SQLv1.0
             • CUSTOM-ROLE-SQLv1.5

[SUBSCRIPTION] subscriptionname2-bu1-hml
  Groupe: atm-grp-bu1-powerusers-app-hr
  ------------------------------------------------------------------------
[FINDING] Duplicate role "CUSTOM-ROLE-NETWORK": v1.0, v2.0, v3.0
           Rôles assignés:
             • CUSTOM-ROLE-NETWORKv1.0
             • CUSTOM-ROLE-NETWORKv2.0
             • CUSTOM-ROLE-NETWORKv3.0

[FINDING] Duplicate role "CUSTOM-ROLE-STORAGE": v1.0, v2.0
           Rôles assignés:
             • CUSTOM-ROLE-STORAGEv1.0
             • CUSTOM-ROLE-STORAGEv2.0

==========================================================================
                        RÉSUMÉ
==========================================================================

  Souscriptions analysées            : 12
  Souscriptions avec groupe assigné  : 10
  Role assignments analysés          : 45

  Rôles dupliqués détectés           : 3
  Souscriptions avec doublons        : 2

[SUCCESS] Analyse terminée.
```
