```bash
#-------------------------------------------------------------------------------
# ANALYSER LES DOUBLONS POUR UNE SOUSCRIPTION DONNÉE
#-------------------------------------------------------------------------------
analyze_subscription_duplicates() {
    local subscription_name="$1"
    local group_name="$2"
    local assignments_json="$3"
    
    declare -A role_versions
    declare -A role_full_names
    
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
    
    # Détecter et afficher les doublons
    local has_duplicates=false
    
    for base_name in "${!role_versions[@]}"; do
        local versions="${role_versions[${base_name}]}"
        local version_count=$(echo "${versions}" | tr ',' '\n' | wc -l)
        
        if [[ ${version_count} -gt 1 ]]; then
            ((++duplicates_found)) || true
            
            # Afficher l'en-tête une seule fois
            if [[ "${has_duplicates}" == "false" ]]; then
                has_duplicates=true
                echo "" >&2
                log_subscription "${subscription_name}" >&2
                echo -e "  Groupe: ${YELLOW}${group_name}${NC}" >&2
                print_sub_separator >&2
            fi
            
            local formatted_versions=$(echo "${versions}" | tr ',' '\n' | sort -V | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            
            log_finding "Duplicate role \"${base_name}\": ${YELLOW}${formatted_versions}${NC}" >&2
            echo "           Rôles assignés:" >&2
            
            # Afficher chaque version
            for version in $(echo "${versions}" | tr ',' '\n' | sort -V); do
                local key="${base_name}|${version}"
                local full_name="${role_full_names[${key}]:-${base_name}${version}}"
                echo "             • ${full_name}" >&2
            done
        fi
    done
    
    # === NOUVEAU : Résumé par souscription ===
    if [[ ${duplicates_found} -gt 0 ]]; then
        echo "" >&2
        echo -e "  ${BOLD}Résumé pour cette souscription:${NC}" >&2
        echo -e "  └─ Rôles dupliqués détectés: ${RED}${duplicates_found}${NC}" >&2
        print_sub_separator >&2
    fi
    # ==========================================
    
    # Seule sortie vers stdout = la valeur numérique
    echo "${duplicates_found}"
}
```    


    
    
```bash
    while IFS= read -r subscription_id; do
        [[ -z "${subscription_id}" ]] && continue
        
        ((++processed))
        
        # Récupérer le nom de la souscription
        local sub_name
        sub_name=$(az account show --subscription "${subscription_id}" --query "name" -o tsv 2>/dev/null || echo "${subscription_id}")
        
        # === NOUVEAU : Ignorer les souscriptions contenant "DELETED" ===
        if [[ "${sub_name^^}" == *"DELETED"* ]]; then
            log_warning "Skipping deleted subscription: ${sub_name}" >&2
            continue
        fi
        # ================================================================
        
        printf "\r  Analyse: [%3d/%3d] %-50s" "${processed}" "${sub_count}" "${sub_name:0:50}"
        
        # ... reste du code
```    

```bash
# Après les autres déclarations de compteurs
local skipped_subscriptions=0

# Dans la boucle, au lieu de juste "continue"
if [[ "${sub_name^^}" == *"DELETED"* ]]; then
    log_warning "Skipping deleted subscription: ${sub_name}" >&2
    ((++skipped_subscriptions))
    continue
fi

# Dans le résumé final
echo "  Souscriptions analysées            : ${sub_count}"
echo "  Souscriptions ignorées (DELETED)   : ${skipped_subscriptions}"
echo "  Souscriptions avec groupe assigné  : ${subscriptions_with_group}"
```
