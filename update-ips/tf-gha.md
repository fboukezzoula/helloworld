```bash

#!/bin/bash

#-------------------------------------------------------------------------------
# SCRIPT: check_and_update_tenant.sh
#-------------------------------------------------------------------------------
#
# DESCRIPTION:
# This script integrates with NetBox and Azure to enforce infrastructure-as-code
# (IaC) governance. It performs the following steps:
#
# 1. Checks if a given Azure subscription name (passed as an argument) matches
#    specific prefixes (gts-, group-, lzsc-).
# 2. If it matches, it fetches the corresponding Azure Subscription ID.
# 3. It then searches for a NetBox tenant whose name is exactly the Subscription ID.
# 4. If a tenant is found, it inspects all its associated IP prefixes.
# 5. It counts how many of these prefixes have the custom field 'automation' set to
#    "Managed by Terraform".
# 6. DECISION:
#    - If one or more prefixes are managed by Terraform, the script exits
#      successfully, as the tenant is correctly managed.
#    - If NO prefixes are managed by Terraform, it flags the tenant for review by
#      renaming both its name and slug, appending "UPDATEBYTF".
#
# This is designed to run in a CI/CD pipeline (e.g., GitHub Actions) to
# automatically identify tenants that are not yet fully managed by Terraform.
#
# USAGE:
# ./check_and_update_tenant.sh "your-azure-subscription-name"
#
# REQUIRED ENVIRONMENT VARIABLES:
# - NETBOX_URL:   The full URL of your NetBox instance (e.g., https://netbox.mycompany.com)
# - NETBOX_TOKEN: Your NetBox API token with read/write permissions.
#
# DEPENDENCIES:
# - jq: Command-line JSON processor.
# - curl: Command-line tool for transferring data with URLs.
# - az: The Azure CLI, expected to be logged in.
#
#-------------------------------------------------------------------------------

# --- Script Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to exit with a non-zero status.
set -o pipefail

# --- 1. Validate Parameters and Environment Variables ---

# Check if the subscription name argument was provided.
if [ -z "${1:-}" ]; then
  echo "❌ ERROR: Azure subscription name is required as the first argument." >&2
  exit 1
fi
AZURE_SUBSCRIPTION_NAME="$1"

# Check for required environment variables.
if [ -z "${NETBOX_URL:-}" ] || [ -z "${NETBOX_TOKEN:-}" ]; then
  echo "❌ ERROR: The NETBOX_URL and NETBOX_TOKEN environment variables must be set." >&2
  exit 1
fi

# Define standard headers for all NetBox API requests.
NETBOX_HEADERS=(-H "Authorization: Token ${NETBOX_TOKEN}" -H "Content-Type: application/json" -H "Accept: application/json")

# --- 2. Check Subscription Name Prefix ---

echo "🔍 Step 1: Analyzing subscription: '${AZURE_SUBSCRIPTION_NAME}'"

if [[ "$AZURE_SUBSCRIPTION_NAME" != "gts-"* && "$AZURE_SUBSCRIPTION_NAME" != "group-"* && "$AZURE_SUBSCRIPTION_NAME" != "lzsc-"* ]]; then
  echo "✅ INFO: Subscription name does not match the required prefixes (gts-, group-, lzsc-). Skipping."
  exit 0
fi

echo "👍 INFO: Subscription name matches. Proceeding..."

# --- 3. Fetch Azure Subscription ID ---

echo "⚙️ Step 2: Fetching Azure Subscription ID..."
# Use Azure CLI to get the subscription ID from its name.
# The 'tsv' output format provides the raw value without quotes.
SUBSCRIPTION_ID=$(az account show --name "$AZURE_SUBSCRIPTION_NAME" --query id --output tsv)

if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "❌ ERROR: Could not find ID for Azure subscription '${AZURE_SUBSCRIPTION_NAME}'. Check the name or your Azure permissions." >&2
  exit 1
fi
echo "✅ SUCCESS: Found Subscription ID: ${SUBSCRIPTION_ID}"

# --- 4. Find Tenant in NetBox ---

TENANT_NAME="$SUBSCRIPTION_ID"
echo "🔍 Step 3: Searching for NetBox tenant named '${TENANT_NAME}'..."

# Query the NetBox API for a tenant with a name matching the subscription ID.
# We only care about the first result.
TENANT_DATA=$(curl -s -X GET "${NETBOX_URL}/api/tenancy/tenants/?name=${TENANT_NAME}" "${NETBOX_HEADERS[@]}" | jq '.results[0]')
TENANT_ID=$(echo "$TENANT_DATA" | jq -r '.id')

# If the tenant ID is null or empty, the tenant does not exist.
if [ -z "$TENANT_ID" ] || [ "$TENANT_ID" == "null" ]; then
  echo "✅ INFO: No tenant found with name '${TENANT_NAME}'. Exiting gracefully."
  exit 0
fi
echo "✅ SUCCESS: Tenant found (ID: ${TENANT_ID})."

# --- 5. Inspect Prefixes for Terraform Management ---

echo "🔍 Step 4: Inspecting prefixes for tenant ID ${TENANT_ID}..."
# Fetch all prefixes associated with this tenant. limit=0 means "get all".
PREFIXES_RESPONSE=$(curl -s -X GET "${NETBOX_URL}/api/ipam/prefixes/?tenant_id=${TENANT_ID}&limit=0" "${NETBOX_HEADERS[@]}")

# Log the total number of prefixes found.
TOTAL_PREFIXES=$(echo "$PREFIXES_RESPONSE" | jq '.count')
echo "ℹ️ INFO: Tenant has ${TOTAL_PREFIXES} prefix(es) in total."

# Count how many prefixes have the "automation" custom field set to "Managed by Terraform".
# - jq extracts the 'automation' field value, filtering out any that are null.
# - grep -c counts the lines that match the string.
# - `|| true` ensures the script doesn't fail if grep finds no matches (it would otherwise exit with code 1).
MATCH_COUNT=$(echo "$PREFIXES_RESPONSE" | \
              jq -r '.results[].custom_fields.automation | select(. != null)' | \
              grep -c -F "Managed by Terraform" || true)

echo "ℹ️ INFO: Found ${MATCH_COUNT} prefix(es) with 'Managed by Terraform'."

# --- 6. Make Decision and Take Action ---

echo "▶️ Step 5: Making a decision..."

if [ "$MATCH_COUNT" -gt 0 ]; then
  # If at least one match is found, our job is done.
  echo "🎉 SUCCESS: At least one prefix is managed by Terraform for tenant '${TENANT_NAME}'."
  echo "➡️ INFO: No action required. Workflow continues."
  exit 0
else
  # If no matches are found, the tenant needs to be updated.
  echo "⚠️ WARNING: No Terraform-managed prefixes found for tenant '${TENANT_NAME}'."
  echo "🔄 ACTION: Renaming tenant and its slug..."

  TENANT_SLUG=$(echo "$TENANT_DATA" | jq -r '.slug')
  NEW_NAME="${TENANT_NAME}UPDATEBYTF"
  NEW_SLUG="${TENANT_SLUG}UPDATEBYTF"
  
  # Construct the JSON payload for the PATCH request.
  JSON_PAYLOAD=$(jq -n --arg name "$NEW_NAME" --arg slug "$NEW_SLUG" '{name: $name, slug: $slug}')

  echo "ℹ️ INFO: New name will be: ${NEW_NAME}"
  echo "ℹ️ INFO: New slug will be: ${NEW_SLUG}"

  # Send the PATCH request to update the tenant in NetBox.
  # -w "%{http_code}" outputs only the HTTP status code.
  # -o /dev/null discards the response body.
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    "${NETBOX_URL}/api/tenancy/tenants/${TENANT_ID}/" \
    "${NETBOX_HEADERS[@]}" \
    --data "$JSON_PAYLOAD")

  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "🎉 SUCCESS: Tenant has been renamed successfully."
    exit 0
  else
    echo "❌ ERROR: Failed to update the tenant. NetBox API returned HTTP Status: ${HTTP_STATUS}" >&2
    exit 1
  fi
fi


```





# Scenario 1: Tenant is correctly managed

```text
🔍 Step 1: Analyzing subscription: 'adam-496875-g3c-hml'
👍 INFO: Subscription name matches. Proceeding...
⚙️ Step 2: Fetching Azure Subscription ID...
✅ SUCCESS: Found Subscription ID: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9
🔍 Step 3: Searching for NetBox tenant named '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'...
✅ SUCCESS: Tenant found (ID: 678).
🔍 Step 4: Inspecting prefixes for tenant ID 678...
ℹ️ INFO: Tenant has 5 prefix(es) in total.
ℹ️ INFO: Found 5 prefix(es) with 'Managed by Terraform'.
▶️ Step 5: Making a decision...
🎉 SUCCESS: At least one prefix is managed by Terraform for tenant '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'.
➡️ INFO: No action required. Workflow continues.
```


# Scenario 2: Tenant needs to be updated (your original case)

```text
🔍 Step 1: Analyzing subscription: 'adam-496875-g3c-hml'
👍 INFO: Subscription name matches. Proceeding...
⚙️ Step 2: Fetching Azure Subscription ID...
✅ SUCCESS: Found Subscription ID: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9
🔍 Step 3: Searching for NetBox tenant named '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'...
✅ SUCCESS: Tenant found (ID: 678).
🔍 Step 4: Inspecting prefixes for tenant ID 678...
ℹ️ INFO: Tenant has 1 prefix(es) in total.
ℹ️ INFO: Found 0 prefix(es) with 'Managed by Terraform'.
▶️ Step 5: Making a decision...
⚠️ WARNING: No Terraform-managed prefixes found for tenant '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'.
🔄 ACTION: Renaming tenant and its slug...
ℹ️ INFO: New name will be: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9UPDATEBYTF
ℹ️ INFO: New slug will be: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9UPDATEBYTF
🎉 SUCCESS: Tenant has been renamed successfully.
```
          
