#-------------------------------------------------------------------------------
# AGGREGATE PERMISSIONS FOR A SUBSCRIPTION
# Collects all permissions from assigned roles and deduplicates them
#-------------------------------------------------------------------------------

aggregate_subscription_permissions() {
    local subscription_id="$1"
    local subscription_name="$2"
    local group_name="$3"
    local group_id="$4"
    local assignments_json="$5"
    
    # Create temporary files for collecting permissions
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_actions="${tmp_dir}/actions.json"
    local tmp_not_actions="${tmp_dir}/not_actions.json"
    local tmp_data_actions="${tmp_dir}/data_actions.json"
    local tmp_not_data_actions="${tmp_dir}/not_data_actions.json"
    local tmp_source_roles="${tmp_dir}/source_roles.json"
    local tmp_output="${tmp_dir}/output.json"
    
    # Initialize empty arrays in temp files
    echo "[]" > "${tmp_actions}"
    echo "[]" > "${tmp_not_actions}"
    echo "[]" > "${tmp_data_actions}"
    echo "[]" > "${tmp_not_data_actions}"
    echo "[]" > "${tmp_source_roles}"
    
    local custom_roles_count=0
    local builtin_roles_count=0
    
    # Process each role assignment
    while IFS= read -r role_name; do
        [[ -z "${role_name}" ]] || [[ "${role_name}" == "null" ]] && continue
        
        # Get role definition
        local role_def
        role_def=$(get_role_definition "${role_name}" "${subscription_id}")
        
        local role_type
        role_type=$(echo "${role_def}" | jq -r '.isCustom // "Unknown"')
        
        # Count role types
        if [[ "${role_type}" == "CustomRole" ]]; then
            ((++custom_roles_count)) || true
        else
            ((++builtin_roles_count)) || true
        fi
        
        # Extract and merge permissions using temp files
        echo "${role_def}" | jq '.actions // []' > "${tmp_dir}/current_actions.json"
        echo "${role_def}" | jq '.notActions // []' > "${tmp_dir}/current_not_actions.json"
        echo "${role_def}" | jq '.dataActions // []' > "${tmp_dir}/current_data_actions.json"
        echo "${role_def}" | jq '.notDataActions // []' > "${tmp_dir}/current_not_data_actions.json"
        
        # Merge arrays using files
        jq -s 'add | unique | sort' "${tmp_actions}" "${tmp_dir}/current_actions.json" > "${tmp_dir}/merged.json" && mv "${tmp_dir}/merged.json" "${tmp_actions}"
        jq -s 'add | unique | sort' "${tmp_not_actions}" "${tmp_dir}/current_not_actions.json" > "${tmp_dir}/merged.json" && mv "${tmp_dir}/merged.json" "${tmp_not_actions}"
        jq -s 'add | unique | sort' "${tmp_data_actions}" "${tmp_dir}/current_data_actions.json" > "${tmp_dir}/merged.json" && mv "${tmp_dir}/merged.json" "${tmp_data_actions}"
        jq -s 'add | unique | sort' "${tmp_not_data_actions}" "${tmp_dir}/current_not_data_actions.json" > "${tmp_dir}/merged.json" && mv "${tmp_dir}/merged.json" "${tmp_not_data_actions}"
        
        # Add to source roles
        jq --arg role "${role_name}" --arg type "${role_type}" '. + [{"name": $role, "type": $type}]' "${tmp_source_roles}" > "${tmp_dir}/merged.json" && mv "${tmp_dir}/merged.json" "${tmp_source_roles}"
        
    done < <(echo "${assignments_json}" | jq -r '.[].roleDefinitionName')
    
    # Calculate statistics
    local actions_count
    local data_actions_count
    actions_count=$(jq 'length' "${tmp_actions}")
    data_actions_count=$(jq 'length' "${tmp_data_actions}")
    
    # Build the final JSON output using files
    jq -n \
        --arg sub_id "${subscription_id}" \
        --arg sub_name "${subscription_name}" \
        --arg grp_name "${group_name}" \
        --arg grp_id "${group_id}" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson custom_count "${custom_roles_count}" \
        --argjson builtin_count "${builtin_roles_count}" \
        --argjson actions_count "${actions_count}" \
        --argjson data_actions_count "${data_actions_count}" \
        --slurpfile actions "${tmp_actions}" \
        --slurpfile not_actions "${tmp_not_actions}" \
        --slurpfile data_actions "${tmp_data_actions}" \
        --slurpfile not_data_actions "${tmp_not_data_actions}" \
        --slurpfile source_roles "${tmp_source_roles}" \
        '{
            "metadata": {
                "subscriptionId": $sub_id,
                "subscriptionName": $sub_name,
                "groupName": $grp_name,
                "groupId": $grp_id,
                "generatedAt": $timestamp,
                "statistics": {
                    "customRolesCount": $custom_count,
                    "builtinRolesCount": $builtin_count,
                    "totalRolesCount": ($custom_count + $builtin_count),
                    "uniqueActionsCount": $actions_count,
                    "uniqueDataActionsCount": $data_actions_count
                }
            },
            "aggregatedPermissions": {
                "actions": $actions[0],
                "notActions": $not_actions[0],
                "dataActions": $data_actions[0],
                "notDataActions": $not_data_actions[0]
            },
            "sourceRoles": $source_roles[0]
        }'
    
    # Cleanup temp files
    rm -rf "${tmp_dir}"
}
