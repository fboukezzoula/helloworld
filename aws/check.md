```bash
#!/usr/bin/env bash
set -euo pipefail

# ======================
# Configuration
# ======================
NETBOX_URL="${NETBOX_URL}"
NETBOX_TOKEN="${NETBOX_TOKEN}"

THRESHOLD=20   # percent free

CIDRS=(
  "10.10.0.0/16"
  "10.20.0.0/20"
  "192.168.100.0/24"
)

MAIL_TO="ops@example.com"
MAIL_SUBJECT="NetBox – IP Capacity Alert (<20% free)"

# ======================
# Internal variables
# ======================
ALERT_COUNT=0
HTML_ROWS=""
TEXT_ALERTS=()

# ======================
# Functions
# ======================
api_call() {
  local cidr="$1"
  curl -s \
    -H "Authorization: Token ${NETBOX_TOKEN}" \
    -H "Accept: application/json" \
    "${NETBOX_URL}/api/ipam/prefixes/?prefix=${cidr}"
}

separator() {
  printf '%*s\n' 80 '' | tr ' ' '-'
}

# ======================
# Console header
# ======================
separator
printf "%-20s | %-10s | %-10s | %-10s | %-6s\n" \
  "CIDR" "Used" "Free" "Total" "Free%"
separator

# ======================
# Main loop
# ======================
for cidr in "${CIDRS[@]}"; do
  response=$(api_call "$cidr")

  count=$(echo "$response" | jq '.count')
  if [[ "$count" -eq 0 ]]; then
    echo "WARN: $cidr not found in NetBox"
    continue
  fi

  prefix=$(echo "$response" | jq '.results[0]')

  used=$(echo "$prefix" | jq '.utilization.used')
  free=$(echo "$prefix" | jq '.utilization.available')
  total=$((used + free))

  # Skip tiny subnets
  [[ "$total" -lt 8 ]] && continue

  free_percent=$(( free * 100 / total ))

  printf "%-20s | %-10s | %-10s | %-10s | %-5s%%\n" \
    "$cidr" "$used" "$free" "$total" "$free_percent"

  # HTML row
  if [[ "$free_percent" -le "$THRESHOLD" ]]; then
    row_color="#f8d7da"
    ALERT_COUNT=$((ALERT_COUNT + 1))
    TEXT_ALERTS+=("• $cidr → ${free_percent}% free (${free} IPs left)")
  else
    row_color="#d4edda"
  fi

  HTML_ROWS+="
    <tr style=\"background-color:${row_color}\">
      <td>${cidr}</td>
      <td>${used}</td>
      <td>${free}</td>
      <td>${total}</td>
      <td><strong>${free_percent}%</strong></td>
    </tr>"
done

separator

# ======================
# HTML email (only if alert)
# ======================
if [[ "$ALERT_COUNT" -gt 0 ]]; then
  HTML_BODY=$(cat <<EOF
<html>
<head>
  <style>
    body { font-family: Arial, Helvetica, sans-serif; }
    h2 { color: #b30000; }
    table {
      border-collapse: collapse;
      width: 100%;
      margin-top: 10px;
    }
    th, td {
      border: 1px solid #cccccc;
      padding: 8px;
      text-align: left;
    }
    th {
      background-color: #f2f2f2;
    }
  </style>
</head>
<body>

<h2>⚠️ NetBox IP Capacity Alert</h2>

<p>
The following CIDRs have less than <strong>${THRESHOLD}%</strong> free IP addresses.
</p>

<table>
  <tr>
    <th>CIDR</th>
    <th>Used</th>
    <th>Free</th>
    <th>Total</th>
    <th>Free %</th>
  </tr>
  ${HTML_ROWS}
</table>

<p>
<strong>Critical CIDRs:</strong><br>
$(printf '%s<br>' "${TEXT_ALERTS[@]}")
</p>

<hr>

<p style="font-size: 12px; color: #666;">
Generated automatically by GitHub Actions<br>
Source: NetBox API
</p>

</body>
</html>
EOF
)

  echo "$HTML_BODY" | sendmail -t <<EOF
To: ${MAIL_TO}
Subject: ${MAIL_SUBJECT}
MIME-Version: 1.0
Content-Type: text/html; charset=UTF-8

$HTML_BODY
EOF

  exit 1
else
  echo "✅ All CIDRs are above the ${THRESHOLD}% free threshold"
fi

```
name: NetBox CIDR capacity check

on:
  schedule:
    - cron: "0 */6 * * *"  # toutes les 6h
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install deps
        run: sudo apt-get update && sudo apt-get install -y jq mailutils

      - name: Run CIDR check
        env:
          NETBOX_URL: ${{ secrets.NETBOX_URL }}
          NETBOX_TOKEN: ${{ secrets.NETBOX_TOKEN }}
        run: bash check_netbox_cidr.sh

