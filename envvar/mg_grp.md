```bash
#-------------------------------------------------------------------------------
# MAPPING BU -> Management Group Root
#-------------------------------------------------------------------------------
declare -A MG_ROOT_MAPPING=(
    ["BU1"]="MG-BU1-ROOT"
    ["BU2"]="MG-BU2-ROOT"
    ["GROUP"]="MG-GROUP-ROOT"
    # Ajouter d'autres BU ici
)

#-------------------------------------------------------------------------------
# MAPPING BU -> Préfixe du groupe EntraID
#-------------------------------------------------------------------------------
declare -A GROUP_PREFIX_MAPPING=(
    ["BU1"]="atm-grp-bu1-powerusers-"
    ["BU2"]="atm-grp-bu2-powerusers-"
    ["GROUP"]="grp-lz-powerusers-"
    # Ajouter d'autres préfixes ici
)


#-------------------------------------------------------------------------------
# RECHERCHER TOUS LES GROUPES CORRESPONDANT AU PATTERN
#-------------------------------------------------------------------------------
find_groups_by_pattern() {
    local bu_name="$1"
    
    # Récupérer le préfixe depuis le mapping
    local group_prefix="${GROUP_PREFIX_MAPPING[${bu_name}]}"
    
    if [[ -z "${group_prefix}" ]]; then
        log_error "Aucun préfixe de groupe défini pour: ${bu_name}" >&2
        echo "[]"
        return
    fi
    
    log_info "Recherche des groupes EntraID avec le pattern: ${group_prefix}*" >&2
    
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
        log_warning "Aucun groupe trouvé avec le pattern: ${group_prefix}*" >&2
        echo "[]"
        return
    fi
    
    local group_count=$(echo "${groups_json}" | jq 'length')
    log_success "Nombre de groupes powerusers trouvés: ${group_count}" >&2
    
    echo "${groups_json}"
}
```

```bash

# main
    local mg_root="${MG_ROOT_MAPPING[${bu_name}]}"
    local group_prefix="${GROUP_PREFIX_MAPPING[${bu_name}]}"
    
    echo ""
    print_separator
    echo -e "${BOLD}  Analyse des rôles dupliqués pour ${bu_name}${NC}"
    print_separator
    echo ""
    echo "  Management Group : ${mg_root}"
    echo "  Pattern groupes  : ${group_prefix}*"
    echo ""
    print_separator
    echo ""
```



