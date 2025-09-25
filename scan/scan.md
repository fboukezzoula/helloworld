```
#!/usr/bin/env bash
# azure-vnet-scan.sh (safe-copy)
#
# Purpose:
#   - Scan Azure subscriptions and list VNets address spaces with:
#       - subnets (count within each address space)
#       - IPv4 IPs used
#       - IPv4 IPs available (accounts for Azure reserved addresses)
#   - Robust logging, timeouts, optional management-group mapping, and selective resource expansion.
#
# Requirements: bash, az, jq, python3
#
# Output CSV (English header):
#   management group,subscription id,subscription name,vnet name,address space,subnets,ips used,ips available,region
#
# Key environment toggles (see docs below):
#   SKIP_MG=1, AZ_TIMEOUT=30, ENABLE_IPV6=0, INCLUDE_EMPTY_SPACE=1,
#   EXPAND_USED_WITH_RESOURCES=0,
#   SKIP_LB=1|SKIP_APPGW=1|SKIP_AZFW=1|SKIP_BASTION=1|SKIP_VNGW=1|SKIP_PLS=1,
#   SUBS_EXCLUDE_REGEX="DELETED"

set -eEuo pipefail

# ------------------------------
# Defaults and global settings
# ------------------------------
OUTFILE="vnet-scan.csv"
SUBS_INPUT=""
MGROUP=""
ALL_SUBS=false
REGION_FILTERS=()

LOG_LEVEL=1   # 0=ERROR, 1=INFO (default), 2=DEBUG
LOG_FILE=""

AZ_TIMEOUT_DEFAULT=30
AZ_TIMEOUT="${AZ_TIMEOUT:-$AZ_TIMEOUT_DEFAULT}"
ENABLE_IPV6="${ENABLE_IPV6:-0}"
INCLUDE_EMPTY_SPACE="${INCLUDE_EMPTY_SPACE:-1}"

# Exclude subscriptions by name (case-insensitive regex). Default: skip any with "DELETED"
SUBS_EXCLUDE_REGEX="${SUBS_EXCLUDE_REGEX:-DELETED}"

# ------------------------------
# Help
# ------------------------------
print_help() {
  cat <<EOF
Usage: $0 [options]
Options:
  -s  Comma-separated subscriptions (ID or name)
  -m  Management Group (ID or name)
  -a  Scan all accessible subscriptions
  -r  Region filter (comma-separated, e.g. "westeurope,francecentral")
  -o  Output CSV (default: $OUTFILE)
  -T  Timeout (seconds) per az command (default: ${AZ_TIMEOUT})
  -v  Verbose (INFO+DEBUG)
  -d  Debug (same as -v)
  -q  Quiet (errors only)
  -L  Log file path
  -h  Help

Environment variables (advanced):
  SKIP_MG=1                      Skip Management Group mapping (faster, default 0)
  AZ_TIMEOUT=30                  Timeout per az command
  ENABLE_IPV6=1                  Include IPv6 (best effort; default 0 = off)
  INCLUDE_EMPTY_SPACE=1          If an address space has zero subnets:
                                 IPv4: available = net_size - 5, used = 0
                                 IPv6: available = net_size - 2 (only if ENABLE_IPV6=1)
  EXPAND_USED_WITH_RESOURCES=1   Add private frontends (LB, AppGW) and managed resources
                                 (Firewall, Bastion, VNet GW, PLS) to "used" (may double-count)
  SKIP_LB=1|SKIP_APPGW=1|SKIP_AZFW=1|SKIP_BASTION=1|SKIP_VNGW=1|SKIP_PLS=1
                                 Skip specific resource additions when EXPAND_USED_WITH_RESOURCES=1
  SUBS_EXCLUDE_REGEX="DELETED"   Exclude subscriptions whose NAME matches this case-insensitive regex
EOF
}

# ------------------------------
# Logging
# ------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local lvl_num=1
  case "$level" in
    ERROR) lvl_num=0 ;;
    WARN)  lvl_num=1 ;;
    INFO)  lvl_num=1 ;;
    DEBUG) lvl_num=2 ;;
    *)     lvl_num=1 ;;
  esac
  if (( LOG_LEVEL >= lvl_num )); then
    if [[ -n "$LOG_FILE" ]]; then
      printf "%s [%s] %s\n" "$(date '+%F %T')" "$level" "$msg" | tee -a "$LOG_FILE" >&2
    else
      printf "%s [%s] %s\n" "$(date '+%F %T')" "$level" "$msg" >&2
    fi
  fi
}

trap 'log ERROR "Error at line $LINENO: $BASH_COMMAND (exit=$?)"; exit $?' ERR

# ------------------------------
# Parse options
# ------------------------------
while getopts "s:m:r:ao:T:vqdL:h" opt; do
  case $opt in
    s) SUBS_INPUT="$OPTARG" ;;
    m) MGROUP="$OPTARG" ;;
    a) ALL_SUBS=true ;;
    r) IFS=',' read -r -a REGION_FILTERS <<< "$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    T) AZ_TIMEOUT="$OPTARG" ;;
    v) LOG_LEVEL=2 ;;
    d) LOG_LEVEL=2 ;;
    q) LOG_LEVEL=0 ;;
    L) LOG_FILE="$OPTARG" ;;
    h) print_help; exit 0 ;;
    *) print_help; exit 1 ;;
  esac
done

# ------------------------------
# Azure CLI guardrails
# ------------------------------
# Avoid interactive extension prompts
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true

# az wrapper with timeout and JSON fallback
safe_az_json() {
  local out=""
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout "${AZ_TIMEOUT}s" az "$@" -o json 2>/dev/null) || true
  else
    out=$(az "$@" -o json 2>/dev/null) || true
    log WARN "'timeout' not found (install coreutils for timeouts)."
  fi
  [[ -z "$out" ]] && echo "[]" || echo "$out"
}

# CSV escape helper
csvq() { local s="${1//\"/\"\"}"; printf "\"%s\"" "$s"; }

# ------------------------------
# Build subscription list
# ------------------------------
declare -a SUBS_LIST=()

# From -s
if [[ -n "$SUBS_INPUT" ]]; then
  IFS=',' read -r -a tmp <<< "$SUBS_INPUT"
  for s in "${tmp[@]}"; do
    if az account show -s "$s" >/dev/null 2>&1; then
      sid=$(az account show -s "$s" -o tsv --query id)
      sname=$(az account show -s "$s" -o tsv --query name)
      SUBS_LIST+=("${sid}::${sname}")
      log DEBUG "Subscription added via -s: $sname ($sid)"
    else
      log WARN "Subscription not found/unreachable: $s"
    fi
  done
fi

# From -m (Management Group)
if [[ -n "$MGROUP" ]]; then
  log INFO "Fetching subscriptions in Management Group: $MGROUP"
  mgjson=$(safe_az_json account management-group show --name "$MGROUP" -e -r)
  if [[ "$mgjson" != "[]" ]]; then
    while IFS=$'\t' read -r fullid sname; do
      [[ -z "$fullid" ]] && continue
      sid=$(echo "$fullid" | sed 's@.*/subscriptions/@@; s@/@@g')
      SUBS_LIST+=("${sid}::${sname}")
      log DEBUG "Subscription added via MG: $sname ($sid)"
    done < <(echo "$mgjson" | jq -r '.. | objects | select(.type=="Subscription") | [.id, (.displayName // .name // "")] | @tsv')
  else
    log WARN "No subscriptions returned by MG '$MGROUP'."
  fi
fi

# From -a or fallback
if $ALL_SUBS || [[ ${#SUBS_LIST[@]} -eq 0 ]]; then
  [[ $ALL_SUBS == true ]] && log INFO "Fetching all accessible subscriptions..."
  while IFS=$'\t' read -r sid sname; do
    SUBS_LIST+=("${sid}::${sname}")
  done < <(safe_az_json account list | jq -r '.[] | [.id, .name] | @tsv')
fi

# Unique
IFS=$'\n' SUBS_LIST=($(printf "%s\n" "${SUBS_LIST[@]}" | awk '!seen[$0]++'))
unset IFS

# Exclude by name (case-insensitive regex)
if [[ -n "${SUBS_EXCLUDE_REGEX:-}" ]]; then
  pattern="$SUBS_EXCLUDE_REGEX"
  before=${#SUBS_LIST[@]}
  filtered=()
  for item in "${SUBS_LIST[@]}"; do
    sname="${item#*::}"
    if echo "$sname" | grep -qiE "$pattern"; then
      log INFO "Skip subscription (name matches exclude): $sname"
      continue
    fi
    filtered+=("$item")
  done
  SUBS_LIST=("${filtered[@]}")
  after=${#SUBS_LIST[@]}
  log INFO "Excluded $((before - after)) subscription(s) by name pattern: ${pattern}"
fi

if [[ ${#SUBS_LIST[@]} -eq 0 ]]; then
  echo "Error: no subscription found after filtering." >&2
  exit 3
fi

log INFO "Subscriptions to scan: ${#SUBS_LIST[@]}"

# ------------------------------
# Subscription -> MG mapping (optional)
# ------------------------------
declare -A SUB_TO_MG
if [[ "${SKIP_MG:-0}" -eq 1 ]]; then
  log INFO "MG mapping skipped (SKIP_MG=1)."
else
  log INFO "Building Subscription -> Management Group mapping..."
  mgroups_json=$(safe_az_json account management-group list)
  mapfile -t mgroups_list < <(echo "$mgroups_json" | jq -r '.[].name' 2>/dev/null || true)
  if [[ ${#mgroups_list[@]} -eq 0 ]]; then
    log WARN "No MGs found; 'management group' column will be 'N/A'."
  else
    for mg in "${mgroups_list[@]}"; do
      members_json=$(safe_az_json account management-group show --name "$mg" -e -r)
      while IFS= read -r fullid; do
        sid=$(echo "$fullid" | sed 's@.*/subscriptions/@@; s@/@@g')
        [[ -n "$sid" ]] && SUB_TO_MG["$sid"]="$mg"
      done < <(echo "$members_json" | jq -r '.. | objects | select(.type=="Subscription") | .id' 2>/dev/null || true)
    done
  fi
fi

# ------------------------------
# CSV header (English)
# ------------------------------
echo "management group,subscription id,subscription name,vnet name,address space,subnets,ips used,ips available,region" > "$OUTFILE"

# ------------------------------
# Compute used/available and per-space subnet count
# ------------------------------
compute_used_and_avail_for_prefix() {
  local prefix="$1"; shift
  local enable_v6="${ENABLE_IPV6:-0}"
  local pairs=("$@")
  ENABLE_V6_ARG="$enable_v6" python3 - "$prefix" "$enable_v6" "${pairs[@]}" <<'PY'
import sys, os, ipaddress
prefix = sys.argv[1]
enable_v6 = sys.argv[2] == "1"
pairs = sys.argv[3:]
include_empty = os.environ.get("INCLUDE_EMPTY_SPACE", "1") == "1"

try:
    net = ipaddress.ip_network(prefix, strict=False)
except Exception:
    print("0 0 0"); sys.exit(0)

if net.version == 6 and not enable_v6:
    print("0 0 0"); sys.exit(0)

used_total = 0
avail_total = 0
seen_subnets = set()

for p in pairs:
    sid=""; cidr_str=""; used_str=""
    if "|||" in p:
        parts = p.split("|||", 2)
        if len(parts) != 3:
            continue
        sid, cidr_str, used_str = parts
    else:
        parts2 = p.split(",", 1)
        if len(parts2) != 2:
            continue
        cidr_str, used_str = parts2

    try:
        used = int(used_str)
        sn = ipaddress.ip_network(cidr_str.strip(), strict=False)
    except Exception:
        continue

    if sn.version != net.version or not sn.subnet_of(net):
        continue

    reserved = 5 if sn.version == 4 else 2
    avail = sn.num_addresses - reserved - used
    if avail < 0:
        avail = 0
    used_total += used
    avail_total += avail
    seen_subnets.add(sid or cidr_str)

sub_count = len(seen_subnets)

# If no subnets exist in this address space, optionally report theoretical availability.
if sub_count == 0 and include_empty:
    if net.version == 4:
        avail_total = max(net.num_addresses - 5, 0)
        used_total = 0
    elif enable_v6:
        avail_total = max(net.num_addresses - 2, 0)
        used_total = 0

print(f"{used_total} {avail_total} {sub_count}")
PY
}

# ------------------------------
# Scan subscriptions
# ------------------------------
for sitem in "${SUBS_LIST[@]}"; do
  sub_id="${sitem%%::*}"
  sub_name="${sitem#*::}"
  log INFO "==== Subscription: $sub_name ($sub_id) ===="
  az account set --subscription "$sub_id" >/dev/null 2>&1 || { log ERROR "Cannot set subscription $sub_id"; continue; }

  vnets_json=$(safe_az_json network vnet list)
  vcount=$(echo "$vnets_json" | jq 'length')
  log INFO "VNets found: $vcount"
  [[ "$vcount" -eq 0 ]] && continue

  mg_name="${SUB_TO_MG[$sub_id]:-N/A}"

  for i in $(seq 0 $((vcount-1))); do
    vnet=$(echo "$vnets_json" | jq ".[$i]")
    vnet_name=$(echo "$vnet" | jq -r '.name')
    location=$(echo "$vnet" | jq -r '.location')

    # region filter
    if [[ ${#REGION_FILTERS[@]} -gt 0 ]]; then
      match=false
      for r in "${REGION_FILTERS[@]}"; do
        if [[ "$location" == "$r" ]]; then match=true; break; fi
      done
      $match || { log DEBUG "Skip VNet $vnet_name ($location) out of region filter"; continue; }
    fi

    # Resource group
    rg=$(echo "$vnet" | jq -r '.resourceGroup // ( .id | capture("/resourceGroups/(?<rg>[^/]+)") | .rg )')

    # Subnets of this VNet (source of truth for CIDRs and ipConfigurations)
    subnets_json=$(safe_az_json network vnet subnet list -g "$rg" --vnet-name "$vnet_name")

    # Base map: used = subnet.ipConfigurations count (NICs + Private Endpoints, etc.)
    declare -A USED_COUNT_BY_SUBNET=()
    while IFS=$'\t' read -r sid ipconfs; do
      [[ -n "$sid" ]] || continue
      USED_COUNT_BY_SUBNET["$sid"]=$(( ipconfs ))
    done < <(echo "$subnets_json" | jq -r '.[] | [.id, ((.ipConfigurations // []) | length)] | @tsv')

    # Optional expansion: add resource frontends (can double-count; use only if you need it)
    if [[ "${EXPAND_USED_WITH_RESOURCES:-0}" -eq 1 ]]; then
      subnet_ids_of_vnet=$(echo "$subnets_json" | jq -r '.[].id')
      is_subnet_of_vnet() { local id="$1"; grep -Fqx -- "$id" <<< "$subnet_ids_of_vnet"; }
      inc_used() { local sid="$1"; local cur="${USED_COUNT_BY_SUBNET["$sid"]:-0}"; USED_COUNT_BY_SUBNET["$sid"]=$((cur + 1)); }

      if [[ "${SKIP_LB:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json network lb list | jq -r '
            .[] | (.frontendIPConfigurations // .frontendIpConfigurations // [])[]? |
            select(.subnet.id!=null) |
            select((.privateIPAddress? // "") | tostring | contains(":") | not) |
            .subnet.id'
        )
      fi
      if [[ "${SKIP_APPGW:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json network application-gateway list | jq -r '
            .[] | (.frontendIPConfigurations // [])[]? |
            select(.subnet.id!=null) |
            select((.privateIPAddress? // "") | tostring | contains(":") | not) |
            .subnet.id'
        )
      fi
      if [[ "${SKIP_AZFW:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json resource list --resource-type Microsoft.Network/azureFirewalls | jq -r '
            .[] | (.properties.ipConfigurations // [])[]? |
            select((.properties.privateIPAddress // "") | tostring | contains(":") | not) |
            .properties.subnet.id? // empty'
        )
      fi
      if [[ "${SKIP_BASTION:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json resource list --resource-type Microsoft.Network/bastionHosts | jq -r '
            .[] | (.properties.ipConfigurations // [])[]? |
            .properties.subnet.id? // empty'
        )
      fi
      if [[ "${SKIP_VNGW:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json resource list --resource-type Microsoft.Network/virtualNetworkGateways | jq -r '
            .[] | (.properties.ipConfigurations // [])[]? |
            .properties.subnet.id? // empty'
        )
      fi
      if [[ "${SKIP_PLS:-0}" -ne 1 ]]; then
        while read -r sid; do [[ -z "$sid" ]] && continue; is_subnet_of_vnet "$sid" && inc_used "$sid"; done < <(
          safe_az_json network private-link-service list | jq -r '
            .[] | (.ipConfigurations // [])[]? |
            .subnet.id? // empty'
        )
      fi
    fi

    # Build "sid|||cidr|||used" triplets for all subnet CIDRs of this VNet
    mapfile -t pairs_for_calc < <(
      echo "$subnets_json" | jq -r '
        .[] | .id as $sid |
        ( (.addressPrefixes? // [ .addressPrefix ])[]? ) as $cidr |
        [$sid, $cidr] | @tsv
      ' | while IFS=$'\t' read -r sid cidr; do
        used="${USED_COUNT_BY_SUBNET["$sid"]:-0}"
        printf "%s|||%s|||%s\n" "$sid" "$cidr" "$used"
      done
    )

    # VNet address spaces
    mapfile -t addr_prefixes < <(echo "$vnet" | jq -r '.addressSpace.addressPrefixes[]? // empty')

    # DEBUG: show VNet/subnet overview
    if (( LOG_LEVEL >= 2 )); then
      total_subnets=$(echo "$subnets_json" | jq 'length')
      log DEBUG "VNet: $vnet_name, region: $location, total subnets: $total_subnets, addrSpaces: ${#addr_prefixes[@]}"
      echo "$subnets_json" | jq -r '
        .[] | [ .name, (.addressPrefix // (.addressPrefixes | join("|"))), ((.ipConfigurations // []) | length) ] | @tsv
      ' | sed 's/^/    /'
    fi

    # Calculate per address space
    for prefix in "${addr_prefixes[@]}"; do
      [[ -z "$prefix" ]] && continue
      res="$(compute_used_and_avail_for_prefix "$prefix" "${pairs_for_calc[@]}")"
      read -r ips_used ips_avail subnets_in_space <<< "$res"
      log DEBUG "  Address space $prefix -> subnets: $subnets_in_space, used: $ips_used, available: $ips_avail"

      # Write CSV safely
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$(csvq "${mg_name}")" \
        "$(csvq "${sub_id}")" \
        "$(csvq "${sub_name}")" \
        "$(csvq "${vnet_name}")" \
        "$(csvq "${prefix}")" \
        "$(csvq "${subnets_in_space}")" \
        "$(csvq "${ips_used}")" \
        "$(csvq "${ips_avail}")" \
        "$(csvq "${location}")" >> "$OUTFILE"
    done
  done
done

echo "✅ Scan complete. Results saved to: $OUTFILE"
```

Documentation

What this script reports

One CSV row per VNet address space:
management group: MG name (or N/A if not mapped)
subscription id / name
vnet name
address space: e.g., 10.0.0.0/16
subnets: number of subnets whose CIDR(s) fall inside that address space (per IP version)
ips used: sum of used IPs across those subnets (base = subnet.ipConfigurations count)
ips available: sum over those subnets: size − reserved − used; Azure reserves 5 IPs in IPv4 subnets, 2 in IPv6
region
Computation details

IPv4 reserved per subnet: 5 addresses
IPv6 reserved per subnet: 2 addresses (only considered if ENABLE_IPV6=1)
Empty address spaces (no subnets):
If INCLUDE_EMPTY_SPACE=1 (default): show theoretical availability
IPv4: net_size − 5 (used=0)
IPv6: net_size − 2 (only if ENABLE_IPV6=1)
If INCLUDE_EMPTY_SPACE=0: availability is 0 for empty address spaces
“Used” base logic:
used = number of ipConfigurations referenced by each subnet (NICs, Private Endpoints, and some managed services that attach NICs)
Optional resource expansion:
EXPAND_USED_WITH_RESOURCES=1 adds 1 used IP for each private frontend or IP configuration from:
Load Balancers (private frontends)
Application Gateways (private frontends)
Azure Firewall
Bastion
Virtual Network Gateways
Private Link Services
Note: this may double-count if the same IP is already represented by a subnet ipConfiguration. Keep this OFF unless you have a proven gap.
Management groups

By default, the script attempts to map subscriptions to their MGs (requires az account extension).
If this is slow or blocked in your environment, set SKIP_MG=1.
Subscription exclusion

Any subscription whose NAME matches SUBS_EXCLUDE_REGEX (case-insensitive) is skipped.
Default: SUBS_EXCLUDE_REGEX="DELETED"
Set SUBS_EXCLUDE_REGEX="" to disable the exclusion.
IPv6

Disabled by default (ENABLE_IPV6=0).
Set ENABLE_IPV6=1 to include IPv6 subnets and theoretical availability for empty IPv6 address spaces.
Requirements

Bash (with mapfile builtin), jq, Python 3, Azure CLI
Logged in: az login (or az login --tenant ...)
Options (CLI)

-s: explicit subscriptions (IDs or names), comma-separated
-m: one management group (ID or name)
-a: all accessible subscriptions
-r: region filter (comma-separated shorthand, e.g. “westeurope,francecentral”)
-o: output CSV filename (default vnet-scan.csv)
-T: per-command timeout for az calls (default AZ_TIMEOUT env or 30 seconds)
-v / -d: verbose/debug logs
-q: quiet logs (errors only)
-L: log file path
Key environment variables

SKIP_MG=1: skip management group mapping
AZ_TIMEOUT=30: per-command timeout
ENABLE_IPV6=1: include IPv6 computations (best effort)
INCLUDE_EMPTY_SPACE=1: show theoretical availability for empty address spaces
EXPAND_USED_WITH_RESOURCES=1: include managed/private frontend resources in “used” (may double-count)
SKIP_LB=1|SKIP_APPGW=1|SKIP_AZFW=1|SKIP_BASTION=1|SKIP_VNGW=1|SKIP_PLS=1: selectively skip resource types
SUBS_EXCLUDE_REGEX="DELETED": case-insensitive name filter for subscription exclusion
Examples

All subscriptions, skip MG mapping, English CSV, debug logs:
SKIP_MG=1 ./azure-vnet-scan.sh -a -o out.csv -v

Specific subscriptions by ID/name, region filter, 20s timeout:
AZ_TIMEOUT=20 ./azure-vnet-scan.sh -s "subId1,Sub Name 2" -r "westeurope,francecentral" -o out.csv -v

Include IPv6 and theoretical availability for empty address spaces:
ENABLE_IPV6=1 INCLUDE_EMPTY_SPACE=1 ./azure-vnet-scan.sh -a -o out.csv -v

Don’t expand resources, but if you need to:
EXPAND_USED_WITH_RESOURCES=1 SKIP_AZFW=1 ./azure-vnet-scan.sh -a -o out.csv -v

Exclude subscriptions with names containing “DELETED” or “DISABLED”:
SUBS_EXCLUDE_REGEX="DELETED|DISABLED" ./azure-vnet-scan.sh -a -o out.csv

Troubleshooting

“Hangs” on MG commands:
Use SKIP_MG=1, or ensure az account extension is installed:
az extension add -n account
“Hangs” or slow resource listing:
Use AZ_TIMEOUT (default 30s) and rerun.
Make sure you run with bash (not sh). mapfile is a bash builtin.
If jq errors with odd strings in logs, ensure you pasted the script intact (no LaTeX-style backslash substitutions).
Tip: integrate with your NetBox updater

This CSV matches what your update_list_available_ips.py expects:
address space, subnets, ips used, ips available
Run the scan, then run your updater to refresh custom fields:
NETBOX_URL=... NETBOX_TOKEN=... python3 update_list_available_ips.py out.csv





