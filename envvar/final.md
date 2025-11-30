
```bash
#!/bin/bash

#===============================================================================
#
#  SCRIPT NAME:    check_duplicate_role_versions.sh
#
#  DESCRIPTION:    Detects Azure custom roles with multiple versions assigned
#                  to powerusers groups within a Business Unit's subscriptions.
#                  
#                  This script helps identify role assignment inconsistencies
#                  where the same custom role (with different versions) is
#                  assigned to the same group within a single subscription.
#
#  AUTHOR:         Cloud Team
#  VERSION:        1.0.0
#  DATE:           2024
#
#  USAGE:          ./check_duplicate_role_versions.sh <BU_NAME> [OPTIONS]
#
#  OPTIONS:
#      --report          Generate a CSV report file
#      --output <file>   Save console output to a file (with colors)
#      --help            Display usage information
#
#  EXAMPLES:
#      ./check_duplicate_role_versions.sh BU1
#      ./check_duplicate_role_versions.sh BU1 --report
#      ./check_duplicate_role_versions.sh BU1 --output report.log
#      ./check_duplicate_role_versions.sh BU1 --report --output report.log
#
#  PREREQUISITES:
#      - Azure CLI installed and configured
#      - jq installed (JSON processor)
#      - Service Principal with required permissions:
#          * Reader on Management Groups
#          * Microsoft.Authorization/roleAssignments/read
#          * Microsoft Graph: Group.Read.All
#
#  ENVIRONMENT VARIABLES:
#      AZURE_CLIENT_ID       - Service Principal Application ID
#      AZURE_CLIENT_SECRET   - Service Principal Secret
#      AZURE_TENANT_ID       - Azure Tenant ID
#
#  EXIT CODES:
#      0 - Success, no duplicates found
#      1 - Duplicates found or error occurred
#
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION - Business Unit Mappings
#-------------------------------------------------------------------------------

# Mapping: BU Name -> Management Group Root
# Add or modify entries based on your Azure governance structure
declare -A MG_ROOT_MAPPING=(
    ["BU1"]="MG-BU1-ROOT"
    ["BU2"]="MG-BU2-ROOT"
    ["GROUP"]="MG-GROUP-ROOT"
    # Add more BUs here as needed
    # ["BU3"]="MG-BU3-ROOT"
)

# Mapping: BU Name -> EntraID Group Prefix
# The script will search for all groups starting with this prefix
declare -A GROUP_PREFIX_MAPPING=(
    ["BU1"]="atm-grp-bu1-powerusers-"
    ["BU2"]="atm-grp-bu2-powerusers-"
    ["GROUP"]="grp-lz-powerusers-"
    # Add more prefixes here as needed
    # ["BU3"]="atm-grp-bu3-powerusers-"
)

#-------------------------------------------------------------------------------
# CONSTANTS
#-------------------------------------------------------------------------------

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_VERSION="1.0.0"

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
readonly NC='\033[0m'  # No Color

#-------------------------------------------------------------------------------
# LOGGING FUNCTIONS
#-------------------------------------------------------------------------------

# Display informational message
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Display success message
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Display warning message
log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Display error message
log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Display finding/duplicate detection message
log_finding() {
    echo -e "${CYAN}[FINDING]${NC} $1"
}

# Display subscription header
log_subscription() {
    echo -e "${MAGENTA}[SUBSCRIPTION]${NC} $1"
}

# Print main separator line
print_separator() {
    echo "=========================================================================="
}

# Print sub-separator line
print_sub_separator() {
    echo "  ------------------------------------------------------------------------"
}

#-------------------------------------------------------------------------------
# DISPLAY HELP
#-------------------------------------------------------------------------------

show_help() {
    cat << EOF
${BOLD}NAME${NC}
    ${SCRIPT_NAME} - Detect duplicate Azure role versions

${BOLD}SYNOPSIS${NC}
    ${SCRIPT_NAME} <BU_NAME> [OPTIONS]

${BOLD}DESCRIPTION${NC}
    Scans all subscriptions within a Business Unit's Management Group hierarchy
    and detects custom roles with multiple versions assigned to powerusers groups.

${BOLD}OPTIONS${NC}
    --report
        Generate a CSV report file with all role assignments.
        File name: role_duplicates_<BU>_<timestamp>.csv

    --output <file>
        Save the console output (with colors) to the specified file.
        Use 'less -R <file>' to view with colors.

    --help, -h
        Display this help message and exit.

${BOLD}AVAILABLE BUSINESS UNITS${NC}
    $(echo "${!MG_ROOT_MAPPING[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')

${BOLD}EXAMPLES${NC}
    # Basic scan for BU1
    ${SCRIPT_NAME} BU1

    # Scan with CSV report generation
    ${SCRIPT_NAME} BU1 --report

    # Scan and save output to file
    ${SCRIPT_NAME} BU1 --output scan_results.log

    # Full scan with all options
    ${SCRIPT_NAME} BU1 --report --output scan_results.log

${BOLD}EXIT CODES${NC}
    0   No duplicates found
    1   Duplicates found or error occurred

${BOLD}AUTHOR${NC}
    Cloud Team - Version ${SCRIPT_VERSION}

EOF
}

#-------------------------------------------------------------------------------
# PREREQUISITES CHECK
#-------------------------------------------------------------------------------

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check Azure CLI installation
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first."
        log_error "Visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    # Check jq installation
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install it first."
        log_error "Run: sudo apt-get install jq"
        exit 1
    fi

    # Check required environment variables for SPN authentication
    if [[ -z "${AZURE_CLIENT_ID:-}" ]]; then
        log_error "Environment variable AZURE_CLIENT_ID is not set."
        exit 1
    fi
    
    if [[ -z "${AZURE_CLIENT_SECRET:-}" ]]; then
        log_error "Environment variable AZURE_CLIENT_SECRET is not set."
        exit 1
    fi
    
    if [[ -z "${AZURE_TENANT_ID:-}" ]]; then
        log_error "Environment variable AZURE_TENANT_ID is not set."
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
        log_error "Azure authentication failed. Please check your credentials."
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# AZURE LOGOUT
#-------------------------------------------------------------------------------

azure_logout() {
    log_info "Logging out from Azure..."
    az logout 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# FIND ENTRA ID GROUPS BY PATTERN
# Searches for all groups matching the configured prefix for the given BU
#-------------------------------------------------------------------------------

find_groups_by_pattern() {
    local bu_name="$1"
    
    # Get the group prefix from configuration
    local group_prefix="${GROUP_PREFIX_MAPPING[${bu_name}]}"
    
    if [[ -z "${group_prefix}" ]]; then
        log_error "No group prefix defined for BU: ${bu_name}" >&2
        echo "[]"
        return
    fi
    
    log_info "Searching for EntraID groups with pattern: ${group_prefix}*" >&2
    
    local groups_json
    
    # Try using az ad group list with JMESPath query
    groups_json=$(az ad group list \
        --query "[?starts_with(displayName, '${group_prefix}')].{displayName:displayName, id:id}" \
        --output json 2>/dev/null)
    
    # Fallback to Microsoft Graph API if first method fails
    if [[ -z "${groups_json}" ]] || [[ "${groups_json}" == "[]" ]]; then
        groups_json=$(az rest \
            --method GET \
            --uri "https://graph.microsoft.com/v1.0/groups?\$filter=startswith(displayName,'${group_prefix}')&\$select=id,displayName" \
            --query "value" \
            --output json 2>/dev/null) || true
    fi
    
    # Check if any groups were found
    if [[ -z "${groups_json}" ]] || [[ "${groups_json}" == "[]" ]]; then
        log_warning "No groups found with pattern: ${group_prefix}*" >&2
        echo "[]"
        return
    fi
    
    local group_count
    group_count=$(echo "${groups_json}" | jq 'length')
    log_success "Found ${group_count} powerusers group(s)" >&2
    
    # Return only the JSON (stdout)
    echo "${groups_json}"
}

#-------------------------------------------------------------------------------
# GET ALL SUBSCRIPTIONS FROM MANAGEMENT GROUP (RECURSIVE)
# Retrieves all subscriptions under a Management Group, including nested MGs
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
    
    # Extract only subscription IDs (filter by type)
    echo "${descendants}" | jq -r '.value[] | select(.type | test("subscriptions$"; "i")) | .name' 2>/dev/null
}

#-------------------------------------------------------------------------------
# GET ROLE ASSIGNMENTS FOR A SUBSCRIPTION
# Finds the powerusers group with assignments on the given subscription
# Returns: JSON object with groupName and assignments array
#-------------------------------------------------------------------------------

get_role_assignments_for_subscription() {
    local subscription_id="$1"
    local groups_json="$2"
    
    # Set the subscription context
    az account set --subscription "${subscription_id}" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "{\"groupName\": \"\", \"assignments\": []}"
        return
    fi
    
    local result_group_name=""
    local result_assignments="[]"
    
    # Iterate through groups to find one with assignments
    while IFS= read -r group_line; do
        [[ -z "${group_line}" ]] && continue
        
        local group_id
        local group_name
        group_id=$(echo "${group_line}" | jq -r '.id')
        group_name=$(echo "${group_line}" | jq -r '.displayName')
        
        [[ -z "${group_id}" ]] || [[ "${group_id}" == "null" ]] && continue
        
        # Get role assignments for this group
        local assignments
        assignments=$(az role assignment list \
            --assignee "${group_id}" \
            --subscription "${subscription_id}" \
            --query "[].{roleDefinitionName:roleDefinitionName, scope:scope}" \
            --output json 2>/dev/null) || continue
        
        # If assignments found, store and break (one group per subscription)
        if [[ -n "${assignments}" ]] && [[ "${assignments}" != "[]" ]]; then
            result_group_name="${group_name}"
            result_assignments="${assignments}"
            break
        fi
        
    done < <(echo "${groups_json}" | jq -c '.[]')
    
    # Return result as JSON
    echo "{\"groupName\": \"${result_group_name}\", \"assignments\": ${result_assignments}}"
}

#-------------------------------------------------------------------------------
# EXTRACT ROLE BASE NAME AND VERSION
# Parses a role name to extract the base name and version number
#
# Supported formats:
#   - CUSTOM-ROLE-NAMEvX.Y
#   - CUSTOM-ROLE-NAME-vX.Y
#   - CUSTOM-ROLE-NAME_vX.Y
#   - CUSTOM-ROLE-NAME-X.Y
#   - CUSTOM-ROLE-NAME_X.Y
#
# Returns: "base_name|version" (pipe-separated)
#-------------------------------------------------------------------------------

extract_role_base_and_version() {
    local role_name="$1"
    local base_name=""
    local version=""
    
    # Pattern: ...vX.Y.Z (v attached)
    if [[ "${role_name}" =~ ^(.+)(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    # Pattern: ...-vX.Y.Z (v with dash)
    elif [[ "${role_name}" =~ ^(.+)-(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    # Pattern: ..._vX.Y.Z (v with underscore)
    elif [[ "${role_name}" =~ ^(.+)_(v[0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="${BASH_REMATCH[2]}"
    # Pattern: ...-X.Y.Z (no v prefix, with dash)
    elif [[ "${role_name}" =~ ^(.+)-([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="v${BASH_REMATCH[2]}"
    # Pattern: ..._X.Y.Z (no v prefix, with underscore)
    elif [[ "${role_name}" =~ ^(.+)_([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        base_name="${BASH_REMATCH[1]}"
        version="v${BASH_REMATCH[2]}"
    else
        # No version pattern detected
        base_name="${role_name}"
        version="no_version"
    fi
    
    # Clean trailing separators from base name
    base_name="${base_name%-}"
    base_name="${base_name%_}"
    
    echo "${base_name}|${version}"
}

#-------------------------------------------------------------------------------
# ANALYZE SUBSCRIPTION FOR DUPLICATE ROLE VERSIONS
# Checks if multiple versions of the same role are assigned to the group
#
# Returns: Number of duplicate role families found (stdout)
# Displays: Findings and summary (stderr)
#-------------------------------------------------------------------------------

analyze_subscription_duplicates() {
    local subscription_name="$1"
    local group_name="$2"
    local assignments_json="$3"
    
    # Associative arrays for tracking
    declare -A role_versions       # base_name -> comma-separated versions
    declare -A role_full_names     # base_name|version -> full role name
    
    local duplicates_found=0
    
    # Parse all role assignments
    while IFS= read -r role_name; do
        [[ -z "${role_name}" ]] || [[ "${role_name}" == "null" ]] && continue
        
        # Extract base name and version
        local parsed
        parsed=$(extract_role_base_and_version "${role_name}")
        local base_name
        local version
        base_name=$(echo "${parsed}" | cut -d'|' -f1)
        version=$(echo "${parsed}" | cut -d'|' -f2)
        
        # Skip roles without version
        [[ "${version}" == "no_version" ]] && continue
        
        # Store full role name for later display
        role_full_names["${base_name}|${version}"]="${role_name}"
        
        # Track versions per base role
        if [[ -z "${role_versions[${base_name}]:-}" ]]; then
            role_versions["${base_name}"]="${version}"
        else
            # Add version if not already present
            if [[ ! "${role_versions[${base_name}]}" =~ (^|,)${version}(,|$) ]]; then
                role_versions["${base_name}"]="${role_versions[${base_name}]},${version}"
            fi
        fi
        
    done < <(echo "${assignments_json}" | jq -r '.[].roleDefinitionName')
    
    # Detect and display duplicates
    local has_duplicates=false
    
    for base_name in "${!role_versions[@]}"; do
        local versions="${role_versions[${base_name}]}"
        local version_count
        version_count=$(echo "${versions}" | tr ',' '\n' | wc -l)
        
        # Check if multiple versions exist (duplicate)
        if [[ ${version_count} -gt 1 ]]; then
            ((++duplicates_found)) || true
            
            # Display header once per subscription
            if [[ "${has_duplicates}" == "false" ]]; then
                has_duplicates=true
                echo "" >&2
                log_subscription "${subscription_name}" >&2
                echo -e "  Group: ${YELLOW}${group_name}${NC}" >&2
                print_sub_separator >&2
            fi
            
            # Format versions for display
            local formatted_versions
            formatted_versions=$(echo "${versions}" | tr ',' '\n' | sort -V | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            
            # Display finding
            log_finding "Duplicate role \"${base_name}\": ${YELLOW}${formatted_versions}${NC}" >&2
            echo "           Assigned roles:" >&2
            
            # List each version with full role name
            for version in $(echo "${versions}" | tr ',' '\n' | sort -V); do
                local key="${base_name}|${version}"
                local full_name="${role_full_names[${key}]:-${base_name}${version}}"
                echo "             • ${full_name}" >&2
            done
        fi
    done
    
    # Display subscription summary if duplicates found
    if [[ ${duplicates_found} -gt 0 ]]; then
        echo "" >&2
        echo -e "  ${BOLD}Subscription Summary:${NC}" >&2
        echo -e "  └─ Duplicate roles detected: ${RED}${duplicates_found}${NC}" >&2
        print_sub_separator >&2
    fi
    
    # Return only the count (stdout)
    echo "${duplicates_found}"
}

#-------------------------------------------------------------------------------
# GENERATE CSV REPORT
# Creates a detailed CSV file with all role assignments and duplicate flags
#-------------------------------------------------------------------------------

generate_csv_report() {
    local -n roles_array=$1
    local output_file="$2"
    
    # Write CSV header
    echo "Subscription,GroupName,RoleName,BaseRoleName,Version,IsDuplicate" > "${output_file}"
    
    # First pass: identify duplicates per subscription/base_name
    declare -A duplicate_keys
    
    for entry in "${roles_array[@]}"; do
        local subscription
        local group_name
        local role_name
        subscription=$(echo "${entry}" | cut -d'|' -f1)
        group_name=$(echo "${entry}" | cut -d'|' -f2)
        role_name=$(echo "${entry}" | cut -d'|' -f3)
        
        local parsed
        parsed=$(extract_role_base_and_version "${role_name}")
        local base_name
        local version
        base_name=$(echo "${parsed}" | cut -d'|' -f1)
        version=$(echo "${parsed}" | cut -d'|' -f2)
        
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
    
    # Mark keys with multiple versions as duplicates
    declare -A is_duplicate
    for key in "${!duplicate_keys[@]}"; do
        local versions="${duplicate_keys[${key}]}"
        local version_count
        version_count=$(echo "${versions}" | tr ',' '\n' | wc -l)
        [[ ${version_count} -gt 1 ]] && is_duplicate["${key}"]="true"
    done
    
    # Second pass: write CSV rows
    for entry in "${roles_array[@]}"; do
        local subscription
        local group_name
        local role_name
        subscription=$(echo "${entry}" | cut -d'|' -f1)
        group_name=$(echo "${entry}" | cut -d'|' -f2)
        role_name=$(echo "${entry}" | cut -d'|' -f3)
        
        local parsed
        parsed=$(extract_role_base_and_version "${role_name}")
        local base_name
        local version
        base_name=$(echo "${parsed}" | cut -d'|' -f1)
        version=$(echo "${parsed}" | cut -d'|' -f2)
        
        local key="${subscription}|${base_name}"
        local dup_flag="No"
        [[ -n "${is_duplicate[${key}]:-}" ]] && dup_flag="Yes"
        
        echo "\"${subscription}\",\"${group_name}\",\"${role_name}\",\"${base_name}\",\"${version}\",\"${dup_flag}\"" >> "${output_file}"
    done
    
    log_success "CSV report generated: ${output_file}"
}

#-------------------------------------------------------------------------------
# MAIN FUNCTION
#-------------------------------------------------------------------------------

main() {
    local bu_name=""
    local generate_report=false
    local output_file=""
    
    #---------------------------------------------------------------------------
    # Parse command line arguments
    #---------------------------------------------------------------------------
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report)
                generate_report=true
                shift
                ;;
            --output)
                if [[ -z "${2:-}" ]] || [[ "$2" == --* ]]; then
                    log_error "Option --output requires a filename"
                    exit 1
                fi
                output_file="$2"
                shift 2
                ;;
            --output=*)
                output_file="${1#*=}"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                log_error "Use --help to see available options"
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
        log_error "Usage: ${SCRIPT_NAME} <BU_NAME> [--report] [--output <file>]"
        log_error "Use --help for more information"
        exit 1
    fi
    
    #---------------------------------------------------------------------------
    # Setup output redirection if requested
    #---------------------------------------------------------------------------
    
    if [[ -n "${output_file}" ]]; then
        # Clear file if it exists
        > "${output_file}"
        # Redirect stdout and stderr to tee
        exec > >(tee -a "${output_file}") 2>&1
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
    # Display header
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}  Duplicate Role Version Analysis for ${bu_name}${NC}"
    print_separator
    echo ""
    echo "  Management Group  : ${mg_root}"
    echo "  Group Pattern     : ${group_prefix}*"
    echo "  Script Version    : ${SCRIPT_VERSION}"
    echo "  Execution Time    : $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "${output_file}" ]]; then
        echo "  Output File       : ${output_file}"
    fi
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
    # Initialize counters and data arrays
    #---------------------------------------------------------------------------
    
    declare -a all_roles=()
    
    local processed=0
    local total_duplicates=0
    local subscriptions_with_duplicates=0
    local subscriptions_with_group=0
    local skipped_subscriptions=0
    
    #---------------------------------------------------------------------------
    # Analyze each subscription
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}                    SUBSCRIPTION ANALYSIS${NC}"
    print_separator
    
    while IFS= read -r subscription_id; do
        # Clean subscription ID (remove whitespace)
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
        printf "\r  Analyzing: [%3d/%3d] %-50s" "${processed}" "${sub_count}" "${sub_name:0:50}"
        
        # Get role assignments for this subscription
        local result
        result=$(get_role_assignments_for_subscription "${subscription_id}" "${groups_json}")
        
        local group_name
        local assignments
        group_name=$(echo "${result}" | jq -r '.groupName')
        assignments=$(echo "${result}" | jq '.assignments')
        
        # Skip if no group found for this subscription
        if [[ -z "${group_name}" ]] || [[ "${group_name}" == "null" ]] || [[ "${group_name}" == "" ]]; then
            continue
        fi
        
        ((++subscriptions_with_group)) || true
        
        local assignment_count
        assignment_count=$(echo "${assignments}" | jq 'length' 2>/dev/null || echo 0)
        
        if [[ ${assignment_count} -gt 0 ]]; then
            # Store role data for CSV report
            while IFS= read -r role_name; do
                [[ -z "${role_name}" ]] || [[ "${role_name}" == "null" ]] && continue
                all_roles+=("${sub_name}|${group_name}|${role_name}")
            done < <(echo "${assignments}" | jq -r '.[].roleDefinitionName')
            
            # Analyze for duplicates
            local dup_count
            dup_count=$(analyze_subscription_duplicates "${sub_name}" "${group_name}" "${assignments}")
            
            if [[ ${dup_count} -gt 0 ]]; then
                ((total_duplicates += dup_count)) || true
                ((++subscriptions_with_duplicates)) || true
            fi
        fi
        
    done <<< "${subscription_ids}"
    
    # Clear progress line
    printf "\r%-80s\r" " "
    
    #---------------------------------------------------------------------------
    # Display global summary
    #---------------------------------------------------------------------------
    
    echo ""
    print_separator
    echo -e "${BOLD}                        GLOBAL SUMMARY${NC}"
    print_separator
    echo ""
    echo "  Subscriptions analyzed              : ${sub_count}"
    echo "  Subscriptions skipped (DELETED)     : ${skipped_subscriptions}"
    echo "  Subscriptions with group assigned   : ${subscriptions_with_group}"
    echo "  Role assignments analyzed           : ${#all_roles[@]}"
    echo ""
    
    if [[ ${total_duplicates} -gt 0 ]]; then
        echo -e "  ${RED}Duplicate role families detected     : ${total_duplicates}${NC}"
        echo -e "  ${RED}Subscriptions with duplicates        : ${subscriptions_with_duplicates}${NC}"
    else
        echo -e "  ${GREEN}Duplicate role families detected     : 0${NC}"
        echo ""
        log_success "No version inconsistencies detected!"
    fi
    
    echo ""
    
    #---------------------------------------------------------------------------
    # Generate CSV report if requested
    #---------------------------------------------------------------------------
    
    if [[ "${generate_report}" == "true" ]] && [[ ${#all_roles[@]} -gt 0 ]]; then
        local report_file="role_duplicates_${bu_name}_$(date +%Y%m%d_%H%M%S).csv"
        generate_csv_report all_roles "${report_file}"
    fi
    
    #---------------------------------------------------------------------------
    # Cleanup and exit
    #---------------------------------------------------------------------------
    
    azure_logout
    
    echo ""
    log_success "Analysis completed."
    echo ""
    
    # Exit with error code if duplicates found (useful for CI/CD pipelines)
    if [[ ${total_duplicates} -gt 0 ]]; then
        exit 1
    fi
    
    exit 0
}

#-------------------------------------------------------------------------------
# SCRIPT ENTRY POINT
#-------------------------------------------------------------------------------

main "$@"
```
