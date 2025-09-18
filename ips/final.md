# Script:

- Colonnes “ips utilisées” et “ips disponibles”.
- Garde-fous: timeouts, désactivation optionnelle des parties coûteuses (SKIP_MG…), installation auto des extensions (sans prompt).
- Calcul des IPs “used/avail” par VNet basé sur les subnets du VNet (source de vérité: ipConfigurations des subnets), pour coller à ce que tu vois dans le portail.
- Optionnel: expansion des “used” par ressources frontales (LB, AppGW, Firewall, Bastion, VNet GW, PLS), désactivée par défaut pour éviter le double comptage.

# Utilisation rapide:

- Timeout global par défaut: 30s (AZ_TIMEOUT). Modifiable par -T 20 ou AZ_TIMEOUT=20.
- Pour ignorer le mapping Management Group: SKIP_MG=1.
- Pour activer l’expansion des “used” via ressources frontales: EXPAND_USED_WITH_RESOURCES=1 (attention au possible double comptage).
- IPv6: par défaut non compté (0/0). Active avec ENABLE_IPV6=1 si tu veux évaluer aussi l’IPv6 (support best effort).

# Exemples:

- SKIP_MG, timeout 20s, logs debug, sortie CSV:
  
```AZ_TIMEOUT=20 SKIP_MG=1 ./azure-vnet-scan.sh -a -r "westeurope,francecentral" -o out.csv -d```

- Avec expansion des ressources frontales:
```EXPAND_USED_WITH_RESOURCES=1 SKIP_MG=1 ./azure-vnet-scan.sh -s "<subId>" -o out.csv -v```

```
#!/usr/bin/env bash
# azure-vnet-scan.sh
# Requirements: az cli, jq, python3, bash
# Usage:
#   ./azure-vnet-scan.sh -a -r "westeurope,francecentral" -o vnets.csv -v
#   ./azure-vnet-scan.sh -s subId1,subName2 -o out.csv -d -L scan.log
#   ./azure-vnet-scan.sh -m MyMgmtGroup -r westeurope -o out.csv
#
# Garde-fous (variables d'env):
#   AZ_TIMEOUT=30       # Timeout (s) pour chaque appel az (défaut 30)
#   SKIP_MG=1           # Ignore le mapping Subscription -> Management Group
#   ENABLE_IPV6=1       # Tente de compter IPv6 (réserves=2). Par défaut: 0 => IPv6 retourne 0/0
#   EXPAND_USED_WITH_RESOURCES=1  # Ajoute LB/AppGW/Firewall/Bastion/VNGW/PLS aux "used" (peut double-compter). Défault: 0
#   SKIP_LB=1|SKIP_APPGW=1|SKIP_AZFW=1|SKIP_BASTION=1|SKIP_VNGW=1|SKIP_PLS=1  # saute sélectivement
#
# Notes:
# - "ips utilisées" = somme des IPs allouées dans les subnets inclus dans l'address space considéré.
#   Basé par défaut sur subnet.ipConfigurations (fidèle au portail). Expansion optionnelle via ressources frontales (voir ci-dessus).
# - "ips disponibles" = somme, pour ces subnets, de (taille - réservées - utilisées).
#   Réserves Azure: 5 en IPv4, 2 en IPv6.

set -eEuo pipefail

OUTFILE="vnet-scan.csv"
SUBS_INPUT=""
MGROUP=""
ALL_SUBS=false
REGION_FILTERS=()
LOG_LEVEL=1   # 0=ERROR, 1=INFO, 2=DEBUG
LOG_FILE=""
AZ_TIMEOUT_DEFAULT=30
AZ_TIMEOUT="${AZ_TIMEOUT:-$AZ_TIMEOUT_DEFAULT}"  # env override
ENABLE_IPV6="${ENABLE_IPV6:-0}"

print_help() {
  cat <<EOF
Usage: $0 [options]
Options:
  -s    Subscriptions (id ou nom) séparées par des virgules
  -m    Management group (id ou nom)
  -a    Scanner toutes les subscriptions accessibles
  -r    Filtre régions (ex: "westeurope,francecentral")
  -o    Fichier CSV de sortie (default: $OUTFILE)
  -T    Timeout (s) pour les commandes az (default: ${AZ_TIMEOUT})
  -v    Verbose (INFO+DEBUG)
  -d    Debug (équivaut à -v)
  -q    Quiet (seulement erreurs)
  -L    Fichier log (ex: scan.log)
  -h    Aide

Garde-fous via variables d'environnement:
  AZ_TIMEOUT=<s>                Timeout (défaut 30s)
  SKIP_MG=1                     Ignore le mapping Subscription->Management Group
  ENABLE_IPV6=1                 Active le calcul IPv6 (best effort)
  EXPAND_USED_WITH_RESOURCES=1  Ajoute LB/AppGW/Firewall/Bastion/VNGW/PLS aux "used" (risque double comptage)
  SKIP_LB=1|SKIP_APPGW=1|SKIP_AZFW=1|SKIP_BASTION=1|SKIP_VNGW=1|SKIP_PLS=1  Filtre fin
EOF
}

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

trap 'log ERROR "Erreur à la ligne $LINENO: $BASH_COMMAND (code=$?)"; exit $?' ERR

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

# Autoriser l'installation auto des extensions sans prompt
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true

# Utilitaire: exécuter "az ... -o json" avec timeout et renvoyer "[]" si vide/erreur
safe_az_json() {
  local out=""
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout "${AZ_TIMEOUT}s" az "$@" -o json 2>/dev/null) || true
  else
    out=$(az "$@" -o json 2>/dev/null) || true
    log WARN "'timeout' non trouvé (installe coreutils si besoin)."
  fi
  if [[ -z "$out" ]]; then echo "[]"; else echo "$out"; fi
}

declare -a SUBS_LIST=()

# --- Résolution des subscriptions ---
if [[ -n "$SUBS_INPUT" ]]; then
  IFS=',' read -r -a tmp <<< "$SUBS_INPUT"
  for s in "${tmp[@]}"; do
    if az account show -s "$s" >/dev/null 2>&1; then
      sid=$(az account show -s "$s" -o tsv --query id)
      sname=$(az account show -s "$s" -o tsv --query name)
      SUBS_LIST+=("${sid}::${sname}")
      log DEBUG "Subscription ajoutée via -s: $sname ($sid)"
    else
      log WARN "Subscription introuvable ou injoignable: $s"
    fi
  done
fi

if [[ -n "$MGROUP" ]]; then
  log INFO "Récupération des subscriptions dans le management group: $MGROUP"
  mgjson=$(safe_az_json account management-group show --name "$MGROUP" -e -r)
  if [[ -n "$mgjson" && "$mgjson" != "[]" ]]; then
    while IFS= read -r item; do
      sid=$(echo "$item" | awk -F'::' '{print $1}' | sed 's@.*/subscriptions/@@; s@/@@g')
      sname=$(echo "$item" | awk -F'::' '{print $2}')
      SUBS_LIST+=("${sid}::${sname}")
      log DEBUG "Subscription ajoutée via MG: $sname ($sid)"
    done < <(echo "$mgjson" | jq -r '.. | objects | select(.type=="Subscription") | "KATEX_INLINE_OPEN.id) :: KATEX_INLINE_OPEN.displayName // .name // "")"')
  else
    log WARN "Aucune subscription renvoyée par le management group '$MGROUP'."
  fi
fi

if $ALL_SUBS; then
  log INFO "Récupération de toutes les subscriptions accessibles..."
  while IFS= read -r item; do
    sid=$(echo "$item" | awk -F'::' '{print $1}')
    sname=$(echo "$item" | awk -F'::' '{print $2}')
    SUBS_LIST+=("${sid}::${sname}")
  done < <(safe_az_json account list | jq -r '.[] | "KATEX_INLINE_OPEN.id) :: KATEX_INLINE_OPEN.name)"')
fi

if [[ ${#SUBS_LIST[@]} -eq 0 ]]; then
  log INFO "Aucune subscription fournie: on prend toutes les subscriptions accessibles."
  while IFS= read -r item; do
    sid=$(echo "$item" | awk -F'::' '{print $1}')
    sname=$(echo "$item" | awk -F'::' '{print $2}')
    SUBS_LIST+=("${sid}::${sname}")
  done < <(safe_az_json account list | jq -r '.[] | "KATEX_INLINE_OPEN.id) :: KATEX_INLINE_OPEN.name)"')
fi

# Unicité
IFS=$'\n' SUBS_LIST=($(printf "%s\n" "${SUBS_LIST[@]}" | awk '!seen[$0]++'))
unset IFS

if [[ ${#SUBS_LIST[@]} -eq 0 ]]; then
  echo "Erreur: aucune subscription trouvée." >&2
  exit 3
fi

log INFO "Subscriptions à scanner: ${#SUBS_LIST[@]}"

# --- Mapping Subscription -> Management Group (optionnel) ---
declare -A SUB_TO_MG
if [[ "${SKIP_MG:-0}" -eq 1 ]]; then
  log INFO "Mapping MG ignoré (SKIP_MG=1)."
else
  log INFO "Construction du mapping Subscription -> Management Group..."
  mgroups_json=$(safe_az_json account management-group list)
  mapfile -t mgroups_list < <(echo "$mgroups_json" | jq -r '.[].name' 2>/dev/null || true)
  if [[ ${#mgroups_list[@]} -eq 0 ]]; then
    log WARN "Aucun MG listé (ou appel indisponible); la colonne 'management group' sera 'N/A'."
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

# --- Header CSV ---
echo "management group,subscription id,subscription name,vnet name,adresse space,nb subnets,ips utilisées,ips disponibles,région" > "$OUTFILE"

# --- Calcul used/avail pour un prefix, à partir des paires "cidr,used" ---
compute_used_and_avail_for_prefix() {
  local prefix="$1"; shift
  local enable_v6="${ENABLE_IPV6:-0}"
  local pairs=("$@")
  ENABLE_V6_ARG="$enable_v6" python3 - "$prefix" "$enable_v6" "${pairs[@]}" <<'PY'
import sys, ipaddress
prefix=sys.argv[1]
enable_v6 = sys.argv[2] == "1"
pairs=sys.argv[3:]
try:
    net=ipaddress.ip_network(prefix, strict=False)
except Exception:
    print("0 0"); sys.exit(0)
if net.version==6 and not enable_v6:
    print("0 0"); sys.exit(0)
used_total=0
avail_total=0
for p in pairs:
    try:
        cidr,used_str=p.split(",",1)
        used=int(used_str)
        sn=ipaddress.ip_network(cidr, strict=False)
    except Exception:
        continue
    if sn.version!=net.version or not sn.subnet_of(net):
        continue
    reserved = 5 if sn.version==4 else 2
    avail = max(sn.num_addresses - reserved - used, 0)
    used_total += used
    avail_total += avail
print(f"{used_total} {avail_total}")
PY
}

# --- Scan par subscription ---
for sitem in "${SUBS_LIST[@]}"; do
  sub_id=$(echo "$sitem" | awk -F'::' '{print $1}')
  sub_name=$(echo "$sitem" | awk -F'::' '{print $2}')
  log INFO "==== Subscription: $sub_name ($sub_id) ===="
  az account set --subscription "$sub_id" >/dev/null 2>&1 || { log ERROR "Impossible de se positionner sur $sub_id"; continue; }

  vnets_json=$(safe_az_json network vnet list)
  vcount=$(echo "$vnets_json" | jq 'length')
  log INFO "VNets trouvés: $vcount"
  [[ "$vcount" -eq 0 ]] && continue

  mg_name="${SUB_TO_MG[$sub_id]:-N/A}"

  for i in $(seq 0 $((vcount-1))); do
    vnet=$(echo "$vnets_json" | jq ".[$i]")
    vnet_name=$(echo "$vnet" | jq -r '.name')
    location=$(echo "$vnet" | jq -r '.location')
    nb_subnets=$(echo "$vnet" | jq -r '(.subnets | length) // 0')

    # Filtre régions
    if [[ ${#REGION_FILTERS[@]} -gt 0 ]]; then
      match=false
      for r in "${REGION_FILTERS[@]}"; do
        if [[ "$location" == "$r" ]]; then match=true; break; fi
      done
      $match || { log DEBUG "Skip VNet $vnet_name ($location) hors filtre"; continue; }
    fi

    # RG du VNet
    rg=$(echo "$vnet" | jq -r '.resourceGroup // ( .id | capture("/resourceGroups/(?<rg>[^/]+)") | .rg )')

    # Subnets du VNet (source de vérité)
    subnets_json=$(safe_az_json network vnet subnet list -g "$rg" --vnet-name "$vnet_name")

    # Map used par subnet: nombre d'ipConfigurations (fidèle au portail)
    declare -A USED_COUNT_BY_SUBNET=()
    while IFS=$'\t' read -r sid ipconfs; do
      [[ -n "$sid" ]] || continue
      USED_COUNT_BY_SUBNET["$sid"]=$(( ipconfs ))
    done < <(echo "$subnets_json" | jq -r '.[] | [.id, ((.ipConfigurations // []) | length)] | @tsv')

    # Expansion optionnelle (LB/AppGW/Firewall/Bastion/VNGW/PLS) — risque de double comptage
    if [[ "${EXPAND_USED_WITH_RESOURCES:-0}" -eq 1 ]]; then
      subnet_ids_of_vnet=$(echo "$subnets_json" | jq -r '.[].id')
      is_subnet_of_vnet() { local id="$1"; grep -Fqx -- "$id" <<< "$subnet_ids_of_vnet"; }
      inc_used() { local sid="$1"; local cur="${USED_COUNT_BY_SUBNET["$sid"]:-0}"; USED_COUNT_BY_SUBNET["$sid"]=$((cur + 1)); }

      if [[ "${SKIP_LB:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json network lb list | jq -r '
          .[] | (.frontendIPConfigurations // .frontendIpConfigurations // [])[]? |
          select(.subnet.id!=null) |
          select((.privateIPAddress? // "") | tostring | contains(":") | not) |
          .subnet.id')
      fi
      if [[ "${SKIP_APPGW:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json network application-gateway list | jq -r '
          .[] | (.frontendIPConfigurations // [])[]? |
          select(.subnet.id!=null) |
          select((.privateIPAddress? // "") | tostring | contains(":") | not) |
          .subnet.id')
      fi
      if [[ "${SKIP_AZFW:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json resource list --resource-type Microsoft.Network/azureFirewalls | jq -r '
          .[] | (.properties.ipConfigurations // [])[]? |
          select((.properties.privateIPAddress // "") | tostring | contains(":") | not) |
          .properties.subnet.id? // empty')
      fi
      if [[ "${SKIP_BASTION:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json resource list --resource-type Microsoft.Network/bastionHosts | jq -r '
          .[] | (.properties.ipConfigurations // [])[]? |
          .properties.subnet.id? // empty')
      fi
      if [[ "${SKIP_VNGW:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json resource list --resource-type Microsoft.Network/virtualNetworkGateways | jq -r '
          .[] | (.properties.ipConfigurations // [])[]? |
          .properties.subnet.id? // empty')
      fi
      if [[ "${SKIP_PLS:-0}" -ne 1 ]]; then
        while read -r sid; do
          [[ -z "$sid" ]] && continue
          is_subnet_of_vnet "$sid" && inc_used "$sid"
        done < <(safe_az_json network private-link-service list | jq -r '
          .[] | (.ipConfigurations // [])[]? |
          .subnet.id? // empty')
      fi
    fi

    # Paires "cidr,used" à partir des subnets du VNet
    mapfile -t pairs_for_calc < <(echo "$subnets_json" | jq -r '
      .[] | .id as $sid | ( (.addressPrefixes? // [ .addressPrefix ])[]? ) | "KATEX_INLINE_OPEN$sid)|KATEX_INLINE_OPEN.)"
    ' | while IFS='|' read -r sid cidr; do
      used="${USED_COUNT_BY_SUBNET["$sid"]:-0}"
      printf "%s,%s\n" "$cidr" "$used"
    done)

    # Adresse spaces du VNet
    mapfile -t addr_prefixes < <(echo "$vnet" | jq -r '.addressSpace.addressPrefixes[]? // empty')

    # DEBUG
    if (( LOG_LEVEL >= 2 )); then
      log DEBUG "VNet: $vnet_name, region: $location, subnets: $nb_subnets, addrSpaces: ${#addr_prefixes[@]}"
      log DEBUG "  Subnets dans $vnet_name:"
      echo "$subnets_json" | jq -r '.[] | "KATEX_INLINE_OPEN.name)\tKATEX_INLINE_OPEN.addressPrefix // (.addressPrefixes|join("|")))\tipConfigs=KATEX_INLINE_OPEN((.ipConfigurations // [])|length))"' | sed 's/^/    /'
    fi

    # Calcul par address space
    for prefix in "${addr_prefixes[@]}"; do
      [[ -z "$prefix" ]] && continue
      res="$(compute_used_and_avail_for_prefix "$prefix" "${pairs_for_calc[@]}")"
      read -r ips_used ips_avail <<< "$res"
      log DEBUG "  Préfix $prefix -> IPs utilisées: $ips_used, disponibles: $ips_avail"
      echo "\"$mg_name\",\"$sub_id\",\"$sub_name\",\"$vnet_name\",\"$prefix\",\"$nb_subnets\",\"$ips_used\",\"$ips_avail\",\"$location\"" >> "$OUTFILE"
    done
  done
done

echo "✅ Scan terminé. Résultats enregistrés dans : $OUTFILE"
```

# Remarques importantes

- Par défaut, on compte les IPs “utilisées” d’un subnet via le nombre d’ipConfigurations que le subnet référence (NICs, Private Endpoints et, selon Azure, d’autres services). C’est généralement ce que le portail utilise pour les “available IPs”.
- Si tu actives EXPAND_USED_WITH_RESOURCES=1, on ajoute explicitement les frontends privés LB/AppGW et quelques ressources gérées. Cela peut double-compter si ces ipConfigurations sont déjà incluses dans subnet.ipConfigurations. À activer seulement si tu constates un écart avéré.
- IPv6: désactivé par défaut (0/0). Active ENABLE_IPV6=1 si nécessaire. Les consommations IPv6 détaillées peuvent être incomplètes selon les services.


