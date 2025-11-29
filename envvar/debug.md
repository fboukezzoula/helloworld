```bash
#-------------------------------------------------------------------------------
# RÉCUPÉRER LES ROLE ASSIGNMENTS POUR LE GROUPE POWERUSERS D'UNE SOUSCRIPTION
#-------------------------------------------------------------------------------
get_role_assignments_for_subscription() {
    local subscription_id="$1"
    local groups_json="$2"
    
    # DEBUG
    echo "[DEBUG] Setting subscription: ${subscription_id}" >&2
    
    az account set --subscription "${subscription_id}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "[DEBUG] Failed to set subscription" >&2
        echo "{\"groupName\": \"\", \"assignments\": []}"
        return
    fi
    
    local result_group_name=""
    local result_assignments="[]"
    
    # DEBUG: compter les groupes
    local group_count=$(echo "${groups_json}" | jq 'length')
    echo "[DEBUG] Checking ${group_count} groups for assignments..." >&2
    
    while IFS= read -r group_line; do
        [[ -z "${group_line}" ]] && continue
        
        local group_id=$(echo "${group_line}" | jq -r '.id')
        local group_name=$(echo "${group_line}" | jq -r '.displayName')
        
        # DEBUG
        echo "[DEBUG] Checking group: ${group_name} (${group_id})" >&2
        
        [[ -z "${group_id}" ]] || [[ "${group_id}" == "null" ]] && continue
        
        local assignments
        assignments=$(az role assignment list \
            --assignee "${group_id}" \
            --subscription "${subscription_id}" \
            --query "[].{roleDefinitionName:roleDefinitionName, scope:scope}" \
            --output json 2>&1)
        
        local az_exit_code=$?
        
        # DEBUG
        echo "[DEBUG] az exit code: ${az_exit_code}" >&2
        echo "[DEBUG] assignments result: ${assignments:0:200}" >&2
        
        if [[ ${az_exit_code} -ne 0 ]]; then
            echo "[DEBUG] az role assignment list failed" >&2
            continue
        fi
        
        if [[ -n "${assignments}" ]] && [[ "${assignments}" != "[]" ]]; then
            echo "[DEBUG] Found assignments for group ${group_name}" >&2
            result_group_name="${group_name}"
            result_assignments="${assignments}"
            break
        fi
        
    done < <(echo "${groups_json}" | jq -c '.[]')
    
    # DEBUG
    echo "[DEBUG] Final result - group: ${result_group_name}, assignments count: $(echo "${result_assignments}" | jq 'length')" >&2
    
    echo "{\"groupName\": \"${result_group_name}\", \"assignments\": ${result_assignments}}"
}
```
