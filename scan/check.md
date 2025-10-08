
```bash
#!/usr/bin/env bash

# --- CONFIGURATION ---

NETBOX_URL="https://netbox.example.com"
API_TOKEN="YOUR_NETBOX_API_TOKEN_HERE"

# Easily editable list: "prefix, expected_id"
PREFIX_CHECKS=(
  "10.2.0.0/15,150"
  "192.168.1.0/24,200"
  "172.16.0.0/12,999"
)

LOG_FILE="netbox_check.log"
JSON_FILE="netbox_check.json"

# --- CODE ---

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

# Clean previous logs
echo "NetBox Prefix ID Check - $(date)" > "$LOG_FILE"
echo "-------------------------------------" >> "$LOG_FILE"
echo "[]" > "$JSON_FILE"

# Header
echo -e "\n${BOLD}🔍 Checking NetBox prefixes...${RESET}\n"
printf "${BOLD}%-20s %-10s %-10s %-10s${RESET}\n" "Prefix" "Expected" "Found" "Result"
printf "%-20s %-10s %-10s %-10s\n" "--------------------" "----------" "----------" "----------"

# Main loop
for entry in "${PREFIX_CHECKS[@]}"; do
  prefix=$(echo "$entry" | cut -d',' -f1 | xargs)
  expected_id=$(echo "$entry" | cut -d',' -f2 | xargs)

  # API call
  response=$(curl -s -H "Authorization: Token $API_TOKEN" \
                   -H "Accept: application/json" \
                   "$NETBOX_URL/api/ipam/prefixes/?prefix=$prefix")

  # Extract id with jq
  id=$(echo "$response" | jq -r '.results[0].id // empty')

  if [[ -z "$id" ]]; then
    result="⚠️  ${YELLOW}No result${RESET}"
    log_result="No result"
    found_id="—"
    status="warning"
  elif [[ "$id" == "$expected_id" ]]; then
    result="✅ ${GREEN}OK${RESET}"
    log_result="OK"
    found_id="$id"
    status="ok"
  else
    result="❌ ${RED}KO${RESET}"
    log_result="KO"
    found_id="$id"
    status="error"
  fi

  # Display formatted result
  printf "%-20s %-10s %-10s %-10b\n" "$prefix" "$expected_id" "$found_id" "$result"

  # Write log
  echo "$prefix | expected=$expected_id | found=$found_id | result=$log_result" >> "$LOG_FILE"

  # Append JSON result
  jq --arg prefix "$prefix" \
     --arg expected "$expected_id" \
     --arg found "$found_id" \
     --arg status "$status" \
     --arg result "$log_result" \
     '. += [{"prefix":$prefix, "expected_id":$expected, "found_id":$found, "status":$status, "result":$result}]' \
     "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"
done

echo -e "\n${CYAN}✨ Check complete.${RESET}"
echo -e "📄 Text log saved to: ${BOLD}$LOG_FILE${RESET}"
echo -e "📊 JSON report saved to: ${BOLD}$JSON_FILE${RESET}\n"
```

💡 Exemple de sortie terminal

```
🔍 Checking NetBox prefixes...

Prefix               Expected   Found      Result    
-------------------- ---------- ---------- ----------
10.2.0.0/15          150        150        ✅ OK
192.168.1.0/24       200        205        ❌ KO
172.16.0.0/12        999        —          ⚠️  No result

✨ Check complete.
📄 Text log saved to: netbox_check.log
📊 JSON report saved to: netbox_check.json
```

📄 Extrait du log texte

```
NetBox Prefix ID Check - Wed Oct  8 15:10:32 2025
-------------------------------------
10.2.0.0/15 | expected=150 | found=150 | result=OK
192.168.1.0/24 | expected=200 | found=205 | result=KO
172.16.0.0/12 | expected=999 | found= | result=No result
```

📊 Fichier JSON (netbox_check.json)

```
[
  {
    "prefix": "10.2.0.0/15",
    "expected_id": "150",
    "found_id": "150",
    "status": "ok",
    "result": "OK"
  },
  {
    "prefix": "192.168.1.0/24",
    "expected_id": "200",
    "found_id": "205",
    "status": "error",
    "result": "KO"
  },
  {
    "prefix": "172.16.0.0/12",
    "expected_id": "999",
    "found_id": "—",
    "status": "warning",
    "result": "No result"
  }
]
```






