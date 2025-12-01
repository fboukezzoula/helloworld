```bash
#!/bin/bash

#===============================================================================
#
#  SCRIPT NAME:    aggregate_role_permissions.sh
#
#  DESCRIPTION:    Aggregates all permissions (actions, dataActions) from 
#                  custom roles assigned to powerusers groups within a 
#                  Business Unit's subscriptions.
#
#                  Outputs a JSON file per subscription with deduplicated
#                  permissions in Azure custom role format.
#
#  AUTHOR:         Cloud Team
#  VERSION:        1.0.0
#  DATE:           2024
#
#  USAGE:          ./aggregate_role_permissions.sh <BU_NAME> [OPTIONS]
#
#  OPTIONS:
#      --output-dir <dir>   Directory for JSON output files (default: ./output)
#      --single-file        Output all subscriptions in a single JSON file
#      --output <file>      Save console output to a file
#      --help               Display usage information
#
#  EXAMPLES:
#      ./aggregate_role_permissions.sh BU1
#      ./aggregate_role_permissions.sh BU1 --output-dir ./reports
#      ./aggregate_role_permissions.sh BU1 --single-file
#
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION - Business Unit Mappings
#-------------------------------------------------------------------------------

declare -A MG_ROOT_MAPPING=(
    ["BU1"]="MG-BU1-ROOT"
    ["BU2"]="MG-BU2-ROOT"
    ["GROUP"]="MG-GROUP-ROOT"
)

declare -A GROUP_PREFIX_MAPPING=(
    ["BU1"]="atm-grp-bu1-powerusers-"
    ["BU2"]="atm-grp-bu2-powerusers-"
    ["GROUP"]="grp-lz-powerusers-"
)

#-------------------------------------------------------------------------------
# CONSTANTS
#-------------------------------------------------------------------------------

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_OUTPUT_DIR="./output"

#-------------------------------------------------------------------------------
# COLORS FOR OUTPUT
#-------------------------------------------------------------------------------

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

#-------------------------------------------------------------------------------
# LOGGING FUNCTIONS
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
# DISPLAY HELP
#-------------------------------------------------------------------------------

show_help() {
    cat << EOF
${BOLD}NAME${NC}
    ${SCRIPT_NAME} - Aggregate Azure role permissions per subscription

${BOLD}SYNOPSIS${NC}
    ${SCRIPT_NAME} <BU_NAME> [OPTIONS]

${BOLD}DESCRIPTION${NC}
    Scans all subscriptions within a Business Unit's Management Group hierarchy
    and aggregates all permissions from custom roles assigned to powerusers groups.
    
    Outputs JSON files in Azure custom role format with deduplicated permissions.

${BOLD}OPTIONS${NC}
    --output-dir <dir>
        Directory for JSON output files (default: ./output)

    --single-file
        Output all subscriptions in a single JSON file instead of one per subscription

    --output <file>
        Save console output to the specified file

    --help, -h
        Display this help message and exit

${BOLD}OUTPUT FORMAT${NC}
    Each subscription generates a JSON file with:
    - Subscription metadata
    - Aggregated actions (deduplicated)
    - Aggregated notActions (deduplicated)
    - Aggregated dataActions (deduplicated)
    - Aggregated notDataActions (deduplicated)
    - List of source roles

${BOLD}EXAMPLES${NC}
    ${SCRIPT_NAME} BU1
    ${SCRIPT_NAME} BU1 --output-dir ./reports
    ${SCRIPT_NAME} BU1 --single-file --output-dir ./reports

EOF
}

#-------------------------------------------------------------------------------
# PREREQUISITES CHECK
#-------------------------------------------------------------------------------

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Run: sudo apt-get install jq"
        exit 1
    fi

    if [[ -z "${AZURE_CLIENT_ID:-}" ]] || \
       [[ -z "${AZURE_CLIENT_SECRET:-}" ]] || \
       [[ -z "${AZURE_TENANT_ID:-}" ]]; then
        log_error "Missing environment variables: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID"
        exit 1
    fi

    log_success "All prerequisites satisfied."
}

#-------------------------------------------------------------------------------
# AZURE AUTHENTICATION
#-------------------------------------------------------------------------------

azure_login() {
    log_info "Authenticating to Azure with Service Principal..."
    
    if az login --service-principal \
        --username "${AZURE_CLIENT_ID}" \
        --password "${AZURE_CLIENT_SECRET}" \
        --tenant "${AZURE_TENANT_ID}" \
        --output none 2>/dev/null; then
        log_success "Azure authentication successful."
    else
        log_error "Azure authentication failed."
        exit 1
    fi
}

azure_logout() {
    log_info "Logging out from Azure..."
    az logout 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# FIND ENTRA ID GROUPS BY PATTERN
#-------------------------------------------------------------------------------

find_groups_by_pattern() {
    local bu_name="$1"
    local group_prefix="${GROUP_PREFIX_MAPPING[${bu_name}]}"
    
    if [[ -z "${group_prefix}" ]]; then
        log_error "No group prefix defined for BU: ${bu_name}" >&2
        echo "[]"
        return
    fi
    
    log_info "Searching for EntraID groups with pattern: ${group_prefix}*" >&2
    
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
        log_warning "No groups found with pattern: ${group_prefix}*" >&2
        echo "[]"
        return
    fi
    
    local group_count
    group_count=$(echo "${groups_json}" | jq 'length')
    log_success "Found ${group_count} powerusers group(s)" >&2
    
    echo "${groups_json}"
}

#-------------------------------------------------------------------------------
# GET ALL SUBSCRIPTIONS FROM MANAGEMENT GROUP (RECURSIVE)
#-------------------------------------------------------------------------------

get_subscriptions_recursive() {
    local mg_name="$1"
    
    log_info "Retrieving subscriptions recursively from MG: ${mg_name}..." >&2
    
    local descendants
    descendants=$(az rest \
        --method GET \
        --uri "https://management.azure.com/providers/Microsoft.Management/managementGroups/${mg_name}/descendants?api-version=2020-05-01" \
        2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "${descendants}" ]]; then
        log_error "Failed to retrieve descendants from MG: ${mg_name}" >&2
        exit 1
    fi
    
    echo "${descendants}" | jq -r '.value[] | select(.type | test("subscriptions$"; "i")) | .name' 2>/dev/null
}

#-------------------------------------------------------------------------------
# GET ROLE ASSIGNMENTS FOR A SUBSCRIPTION
#-------------------------------------------------------------------------------

get_role_assignments_for_subscription() {
    local subscription_id="$1"
    local groups_json="$2"
    
    az account set --subscription "${subscription_id}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "{\"groupName\": \"\", \"groupId\": \"\", \"assignments\": []}"
        return
    fi
    
    local result_group_name=""
    local result_group_id=""
    local result_assignments="[]"
    
    while IFS= read -r group_line; do
        [[ -z "${group_line}" ]] && continue
        
        local group_id
        local group_name
        group_id=$(echo "${group_line}" | jq -r '.id')
        group_name=$(echo "${group_line}" | jq -r '.displayName')
        
        [[ -z "${group_id}" ]] || [[ "${group_id}" == "null" ]] && continue
        
        local assignments
        assignments=$(az role assignment list \
            --assignee "${group_id}" \
            --subscription "${subscription_id}" \
            --query "[].{roleDefinitionName:roleDefinitionName, roleDefinitionId:roleDefinitionId, scope:scope}" \
            --output json 2>/dev/null) || continue
        
        if [[ -n "${assignments}" ]] && [[ "${assignments}" != "[]" ]]; then
            result_group_name="${group_name}"
            result_group_id="${group_id}"
            result_assignments="${assignments}"
            break
        fi
        
    done < <(echo "${groups_json}" | jq -c '.[]')
    
    echo "{\"groupName\": \"${result_group_name}\", \"groupId\": \"${result_group_id}\", \"assignments\": ${result_assignments}}"
}

#-------------------------------------------------------------------------------
# GET ROLE DEFINITION DETAILS
# Retrieves the full role definition including actions and dataActions
#-------------------------------------------------------------------------------

get_role_definition() {
    local role_name="$1"
    local subscription_id="$2"
    
    # Get role definition by name
    local role_def
    role_def=$(az role definition list \
        --name "${role_name}" \
        --scope "/subscriptions/${subscription_id}" \
        --query "[0].{name:roleName, actions:permissions[0].actions, notActions:permissions[0].notActions, dataActions:permissions[0].dataActions, notDataActions:permissions[0].notDataActions, isCustom:roleType}" \
        --output json 2>/dev/null)
    
    if [[ -z "${role_def}" ]] || [[ "${role_def}" == "null" ]]; then
        echo "{\"name\": \"${role_name}\", \"actions\": [], \"notActions\": [], \"dataActions\": [], \"notDataActions\": [], \"isCustom\": \"Unknown\"}"
        return
    fi
    
    echo "${role_def}"
}

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
    
    # Arrays to collect all permissions
    local all_actions="[]"
    local all_not_actions="[]"
    local all_data_actions="[]"
    local all_not_data_actions="[]"
    local source_roles="[]"
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
        
        # Extract permissions
        local actions
        local not_actions
        local data_actions
        local not_data_actions
        
        actions=$(echo "${role_def}" | jq '.actions // []')
        not_actions=$(echo "${role_def}" | jq '.notActions // []')
        data_actions=$(echo "${role_def}" | jq '.dataActions // []')
        not_data_actions=$(echo "${role_def}" | jq '.notDataActions // []')
        
        # Merge arrays
        all_actions=$(echo "${all_actions} ${actions}" | jq -s 'add | unique | sort')
        all_not_actions=$(echo "${all_not_actions} ${not_actions}" | jq -s 'add | unique | sort')
        all_data_actions=$(echo "${all_data_actions} ${data_actions}" | jq -s 'add | unique | sort')
        all_not_data_actions=$(echo "${all_not_data_actions} ${not_data_actions}" | jq -s 'add | unique | sort')
        
        # Add to source roles list
        source_roles=$(echo "${source_roles}" | jq --arg role "${role_name}" --arg type "${role_type}" '. + [{"name": $role, "type": $type}]')
        
    done < <(echo "${assignments_json}" | jq -r '.[].roleDefinitionName')
    
    # Build the final JSON output
    local output_json
    output_json=$(jq -n \
        --arg sub_id "${subscription_id}" \
        --arg sub_name "${subscription_name}" \
        --arg grp_name "${group_name}" \
        --arg grp_id "${group_id}" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson custom_count "${custom_roles_count}" \
        --argjson builtin_count "${builtin_roles_count}" \
        --argjson actions "${all_actions}" \
        --argjson not_actions "${all_not_actions}" \
        --argjson data_actions "${all_data_actions}" \
        --argjson not_data_actions "${all_not_data_actions}" \
        --argjson source_roles "${source_roles}" \
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
                    "uniqueActionsCount": ($actions | length),
                    "uniqueDataActionsCount": ($data_actions | length)
                }
            },
            "aggregatedPermissions": {
                "actions": $actions,
                "notActions": $not_actions,
                "dataActions": $data_actions,
                "notDataActions": $not_data_actions
            },
            "sourceRoles": $source_roles
        }')
    
    echo "${output_json}"
}

#-------------------------------------------------------------------------------
# DISPLAY SUBSCRIPTION SUMMARY
#-------------------------------------------------------------------------------

display_subscription_summary() {
    local subscription_name="$1"
    local group_name="$2"
    local json_output="$3"
    
    local custom_count
    local builtin_count
    local actions_count
    local data_actions_count
    
    custom_count=$(echo "${json_output}" | jq '.metadata.statistics.customRolesCount')
    builtin_count=$(echo "${json_output}" | jq '.metadata.statistics.builtinRolesCount')
    actions_count=$(echo "${json_output}" | jq '.metadata.statistics.uniqueActionsCount')
    data_actions_count=$(echo "${json_output}" | jq '.metadata.statistics.uniqueDataActionsCount')
    
    echo "" >&2
    log_subscription "${subscription_name}" >&2
    echo -e "  Group: ${YELLOW}${group_name}${NC}" >&2
    print_sub_separator >&2
    echo -e "  ${CYAN}Roles analyzed:${NC}" >&2
    echo -e "    • Custom roles    : ${custom_count}" >&2
    echo -e "    • Built-in roles  : ${builtin_count}" >&2
    echo -e "  ${CYAN}Aggregated permissions:${NC}" >&2
    echo -e "    • Unique actions      : ${GREEN}${actions_count}${NC}" >&2
    echo -e "    • Unique dataActions  : ${GREEN}${data_actions_count}${NC}" >&2
    print_sub_separator >&2
}

#-------------------------------------------------------------------------------
# SAVE JSON OUTPUT
#-------------------------------------------------------------------------------

save_json_output() {
    local json_content="$1"
    local output_file="$2"
    
    echo "${json_content}" | jq '.' > "${output_file}"
    log_success "Saved: ${output_file}" >&2
}

#-------------------------------------------------------------------------------
# MAIN FUNCTION
#-------------------------------------------------------------------------------

main() {
    local bu_name=""
    local output_dir="${DEFAULT_OUTPUT_DIR}"
    local single_file=false
    local console_output_file=""
    
    #---------------------------------------------------------------------------
    # Parse command line arguments
    #---------------------------------------------------------------------------
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "Option --output-dir requires a directory path"
                    exit 1
                fi
                output_dir="$2"
                shift 2
                ;;
            --output-dir=*)
                output_dir="${1#*=}"
                shift
                ;;
            --single-file)
                single_file=true
                shift
                ;;
            --output)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "Option --output requires a filename"
                    exit 1
                fi
                console_output_file="$2"
                shift 2
                ;;
            --output=*)
                console_output_file="${1#*=}"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                log_error "Use --help for available options"
                exit 1
                ;;
            *)
                if [[ -z "${bu_name}" ]]; then
                    bu_name="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    #---------------------------------------------------------------------------
    # Validate BU parameter
    #---------------------------------------------------------------------------
    
    if [[ -z "${bu_name}" ]]; then
        log_error "Usage: ${SCRIPT_NAME} <BU_NAME> [OPTIONS]"
        log_error "Use --help for more information"
        exit 1
    fi
    
    #---------------------------------------------------------------------------
    # Setup console output redirection if requested
    #---------------------------------------------------------------------------
    
    if [[ -n "${console_output_file}" ]]; then
        > "${console_output_file}"
        exec > >(tee -a "${console_output_file}") 2>&1
    fi
    
    #---------------------------------------------------------------------------
    # Normalize and validate BU name
    #---------------------------------------------------------------------------
    
    bu_name=$(echo "${bu_name}" | tr '[:lower:]' '[:upper:]')
    
    if [[ -z "${MG_ROOT_MAPPING[${bu_name}]:-}" ]]; then
        log_error "Unknown Business Unit: ${bu_name}"
        log_error "Available BUs: ${!MG_ROOT_MAPPING[*]}"
        exit 1
    fi
    
    local mg_root="${MG_ROOT_MAPPING[${bu_name}]}"
    local group_prefix="${GROUP_PREFIX_MAPPING[${bu_name}]}"
    
    #---------------------------------------------------------------------------
    # Create output directory
    #---------------------------------------------------------------------------
    
    mkdir -p "${output_dir}"
    
    #---------------------------------------------------------------------------
    # Display header
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}  Permission Aggregation for ${bu_name}${NC}"
    print_separator
    echo ""
    echo "  Management Group  : ${mg_root}"
    echo "  Group Pattern     : ${group_prefix}*"
    echo "  Output Directory  : ${output_dir}"
    echo "  Single File Mode  : ${single_file}"
    echo "  Script Version    : ${SCRIPT_VERSION}"
    echo "  Execution Time    : $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    print_separator
    echo ""
    
    #---------------------------------------------------------------------------
    # Run prerequisites check and authenticate
    #---------------------------------------------------------------------------
    
    check_prerequisites
    azure_login
    
    #---------------------------------------------------------------------------
    # Find powerusers groups
    #---------------------------------------------------------------------------
    
    local groups_json
    groups_json=$(find_groups_by_pattern "${bu_name}")
    
    local group_count
    group_count=$(echo "${groups_json}" | jq 'length')
    
    if [[ ${group_count} -eq 0 ]]; then
        log_error "No powerusers groups found for ${bu_name}"
        azure_logout
        exit 1
    fi
    
    #---------------------------------------------------------------------------
    # Get all subscriptions from Management Group
    #---------------------------------------------------------------------------
    
    local subscription_ids
    subscription_ids=$(get_subscriptions_recursive "${mg_root}")
    
    if [[ -z "${subscription_ids}" ]]; then
        log_warning "No subscriptions found in MG: ${mg_root}"
        azure_logout
        exit 0
    fi
    
    local sub_count
    sub_count=$(echo "${subscription_ids}" | grep -c '^' || echo 0)
    log_success "Found ${sub_count} subscription(s) to analyze"
    
    #---------------------------------------------------------------------------
    # Initialize counters and data
    #---------------------------------------------------------------------------
    
    local processed=0
    local subscriptions_processed=0
    local skipped_subscriptions=0
    local all_subscriptions_json="[]"
    
    #---------------------------------------------------------------------------
    # Process each subscription
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}                    SUBSCRIPTION ANALYSIS${NC}"
    print_separator
    
    while IFS= read -r subscription_id; do
        subscription_id=$(echo "${subscription_id}" | tr -d '[:space:]')
        [[ -z "${subscription_id}" ]] && continue
        
        ((++processed)) || true
        
        # Get subscription name
        local sub_name
        sub_name=$(az account show --subscription "${subscription_id}" --query "name" -o tsv 2>/dev/null || echo "${subscription_id}")
        
        # Skip deleted subscriptions
        if [[ "${sub_name^^}" == *"DELETED"* ]]; then
            log_warning "Skipping deleted subscription: ${sub_name}" >&2
            ((++skipped_subscriptions)) || true
            continue
        fi
        
        # Display progress
        printf "\r  Processing: [%3d/%3d] %-50s" "${processed}" "${sub_count}" "${sub_name:0:50}"
        
        # Get role assignments
        local result
        result=$(get_role_assignments_for_subscription "${subscription_id}" "${groups_json}")
        
        local group_name
        local group_id
        local assignments
        group_name=$(echo "${result}" | jq -r '.groupName')
        group_id=$(echo "${result}" | jq -r '.groupId')
        assignments=$(echo "${result}" | jq '.assignments')
        
        # Skip if no group found
        if [[ -z "${group_name}" ]] || [[ "${group_name}" == "null" ]] || [[ "${group_name}" == "" ]]; then
            continue
        fi
        
        local assignment_count
        assignment_count=$(echo "${assignments}" | jq 'length' 2>/dev/null || echo 0)
        
        if [[ ${assignment_count} -gt 0 ]]; then
            ((++subscriptions_processed)) || true
            
            # Aggregate permissions
            local aggregated_json
            aggregated_json=$(aggregate_subscription_permissions \
                "${subscription_id}" \
                "${sub_name}" \
                "${group_name}" \
                "${group_id}" \
                "${assignments}")
            
            # Display summary
            display_subscription_summary "${sub_name}" "${group_name}" "${aggregated_json}"
            
            if [[ "${single_file}" == "true" ]]; then
                # Add to array for single file output
                all_subscriptions_json=$(echo "${all_subscriptions_json}" | jq --argjson sub "${aggregated_json}" '. + [$sub]')
            else
                # Save individual file
                local safe_sub_name
                safe_sub_name=$(echo "${sub_name}" | tr ' /:' '_')
                local output_file="${output_dir}/${safe_sub_name}_permissions.json"
                save_json_output "${aggregated_json}" "${output_file}"
            fi
        fi
        
    done <<< "${subscription_ids}"
    
    # Clear progress line
    printf "\r%-80s\r" " "
    
    #---------------------------------------------------------------------------
    # Save single file if requested
    #---------------------------------------------------------------------------
    
    if [[ "${single_file}" == "true" ]] && [[ "${subscriptions_processed}" -gt 0 ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        local single_output_file="${output_dir}/${bu_name}_all_permissions_${timestamp}.json"
        
        # Wrap in a container with metadata
        local final_json
        final_json=$(jq -n \
            --arg bu "${bu_name}" \
            --arg mg "${mg_root}" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson subs_count "${subscriptions_processed}" \
            --argjson subscriptions "${all_subscriptions_json}" \
            '{
                "metadata": {
                    "businessUnit": $bu,
                    "managementGroup": $mg,
                    "generatedAt": $timestamp,
                    "subscriptionsCount": $subs_count
                },
                "subscriptions": $subscriptions
            }')
        
        save_json_output "${final_json}" "${single_output_file}"
    fi
    
    #---------------------------------------------------------------------------
    # Display global summary
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}                        GLOBAL SUMMARY${NC}"
    print_separator
    echo ""
    echo "  Subscriptions analyzed            : ${sub_count}"
    echo "  Subscriptions skipped (DELETED)   : ${skipped_subscriptions}"
    echo "  Subscriptions processed           : ${subscriptions_processed}"
    echo ""
    echo "  Output directory                  : ${output_dir}"
    if [[ "${single_file}" == "true" ]]; then
        echo "  Output mode                       : Single file"
    else
        echo "  Output mode                       : One file per subscription"
    fi
    echo ""
    
    #---------------------------------------------------------------------------
    # Cleanup and exit
    #---------------------------------------------------------------------------
    
    azure_logout
    
    echo ""
    log_success "Permission aggregation completed."
    echo ""
    
    exit 0
}

#-------------------------------------------------------------------------------
# SCRIPT ENTRY POINT
#-------------------------------------------------------------------------------

main "$@"
```


📋 Usage

```bash
# Basic usage - one JSON file per subscription
./aggregate_role_permissions.sh BU1

# Specify output directory
./aggregate_role_permissions.sh BU1 --output-dir ./reports

# Single file with all subscriptions
./aggregate_role_permissions.sh BU1 --single-file

# All options
./aggregate_role_permissions.sh BU1 --single-file --output-dir ./reports --output console.log
```

📊 Format de sortie JSON (par souscription)

```json
{
  "metadata": {
    "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "subscriptionName": "subscriptionname1-bu1-dev",
    "groupName": "atm-grp-bu1-powerusers-app-finance",
    "groupId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "generatedAt": "2024-01-15T10:30:00Z",
    "statistics": {
      "customRolesCount": 5,
      "builtinRolesCount": 2,
      "totalRolesCount": 7,
      "uniqueActionsCount": 45,
      "uniqueDataActionsCount": 12
    }
  },
  "aggregatedPermissions": {
    "actions": [
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/start/action",
      "Microsoft.Network/networkInterfaces/read",
      "Microsoft.Storage/storageAccounts/read"
    ],
    "notActions": [
      "Microsoft.Authorization/*/Delete"
    ],
    "dataActions": [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.KeyVault/vaults/secrets/getSecret/action"
    ],
    "notDataActions": []
  },
  "sourceRoles": [
    {
      "name": "CUSTOM-ROLE-SQLv2.0",
      "type": "CustomRole"
    },
    {
      "name": "CUSTOM-ROLE-NETWORKv1.5",
      "type": "CustomRole"
    },
    {
      "name": "Reader",
      "type": "BuiltInRole"
    }
  ]
}
```

📊 Exemple de sortie console

```text
==========================================================================
  Permission Aggregation for BU1
==========================================================================

  Management Group  : MG-BU1-ROOT
  Group Pattern     : atm-grp-bu1-powerusers-*
  Output Directory  : ./output
  Single File Mode  : false
  Script Version    : 1.0.0
  Execution Time    : 2024-01-15 10:30:00

==========================================================================

[INFO] Checking prerequisites...
[SUCCESS] All prerequisites satisfied.
[INFO] Authenticating to Azure with Service Principal...
[SUCCESS] Azure authentication successful.
[SUCCESS] Found 12 powerusers group(s)
[SUCCESS] Found 8 subscription(s) to analyze

==========================================================================
                    SUBSCRIPTION ANALYSIS
==========================================================================

[SUBSCRIPTION] subscriptionname1-bu1-dev
  Group: atm-grp-bu1-powerusers-app-finance
  ------------------------------------------------------------------------
  Roles analyzed:
    • Custom roles    : 5
    • Built-in roles  : 2
  Aggregated permissions:
    • Unique actions      : 45
    • Unique dataActions  : 12
  ------------------------------------------------------------------------
[SUCCESS] Saved: ./output/subscriptionname1-bu1-dev_permissions.json

[SUBSCRIPTION] subscriptionname2-bu1-hml
  Group: atm-grp-bu1-powerusers-app-hr
  ------------------------------------------------------------------------
  Roles analyzed:
    • Custom roles    : 3
    • Built-in roles  : 1
  Aggregated permissions:
    • Unique actions      : 28
    • Unique dataActions  : 5
  ------------------------------------------------------------------------
[SUCCESS] Saved: ./output/subscriptionname2-bu1-hml_permissions.json

==========================================================================
                        GLOBAL SUMMARY
==========================================================================

  Subscriptions analyzed            : 8
  Subscriptions skipped (DELETED)   : 1
  Subscriptions processed           : 6

  Output directory                  : ./output
  Output mode                       : One file per subscription

[SUCCESS] Permission aggregation completed.

```

# Commandes de test

```bash
# Test basique
./aggregate_role_permissions.sh BU1

# Vérifier les fichiers générés
ls -la ./output/

# Voir le contenu d'un fichier JSON
cat ./output/subscriptionname-bu1-dev_permissions.json | jq '.'

# Voir uniquement les actions agrégées
cat ./output/subscriptionname-bu1-dev_permissions.json | jq '.aggregatedPermissions.actions'
```

# Rappel des options

```text
Option	                                Description

--output-dir ./reports	                Changer le dossier de sortie
--single-file	                          Un seul JSON pour toutes les souscriptions
--output console.log	                  Sauvegarder la console
```

