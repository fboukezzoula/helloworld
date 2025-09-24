Love it. Let’s keep your emoji summary field and add two numeric custom fields on Prefixes:

ips_used (label: “IP Used”) → integer
ips_available (label: “IP Availables”) → integer
The updater will:

Ensure these two custom fields exist (auto-create if missing).
Continue updating list_available_ips (emoji summary).
Also write numeric values into ips_used and ips_available.
Still supports creating missing container prefixes with the tag ip-availables-sync.
Drop-in replacement script


```python
#!/usr/bin/env python3
# update_list_available_ips.py
# Force-update NetBox custom fields on IPAM > Prefixes from the CSV produced by azure-vnet-scan.sh.
# - Keeps the emoji summary in "list_available_ips"
# - Adds numeric fields: "ips_used" (IP Used) and "ips_available" (IP Availables)
# - Optional: --create-missing to create global container prefixes tagged "ip-availables-sync"
# - Status thresholds configurable via --green-th/--orange-th or env (AVAIL_GREEN_TH/AVAIL_ORANGE_TH)

import os, sys, csv, argparse, ipaddress
import pynetbox

# Custom fields (names are API keys; labels are what you see in UI)
CF_SUMMARY_NAME = "list_available_ips"
CF_SUMMARY_DEF = {
    "name": CF_SUMMARY_NAME,
    "label": "List available IPs",
    "type": "text",
    "content_types": ["ipam.prefix"],
    "description": "Summary of used and available IPs in the prefix",
    "required": False,
}

CF_USED_NAME = "ips_used"
CF_USED_DEF = {
    "name": CF_USED_NAME,
    "label": "IP Used",
    "type": "integer",
    "content_types": ["ipam.prefix"],
    "description": "Number of IP addresses used in the prefix",
    "required": False,
}

CF_AVAIL_NAME = "ips_available"
CF_AVAIL_DEF = {
    "name": CF_AVAIL_NAME,
    "label": "IP Availables",
    "type": "integer",
    "content_types": ["ipam.prefix"],
    "description": "Number of IP addresses available in the prefix",
    "required": False,
}

# Tag used when creating missing container prefixes
TAG_NAME = "ip-availables-sync"
TAG_SLUG = "ip-availables-sync"
TAG_COLOR = "teal"

CREATE_DESC = os.environ.get("IP_SYNC_CREATE_DESC", "⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC")

def to_int(s, default=0):
    try:
        s = (s or "").replace(" ", "").replace(",", "")
        return int(float(s)) if s else default
    except Exception:
        return default

def to_float(s, default=None):
    try:
        s = (s or "").strip().replace("%", "").replace(",", ".")
        return float(s)
    except Exception:
        return default

def fmt_int(n):
    try:
        n = int(n)
    except Exception:
        return "0"
    return f"{n:,}".replace(",", " ")

def avail_pct(prefix_cidr, ips_avail, ipv4_reserved=5):
    try:
        net = ipaddress.ip_network(prefix_cidr, strict=False)
    except Exception:
        return None
    if net.version == 6:
        return None  # skip % for IPv6 (adjust if desired)
    usable = max(net.num_addresses - ipv4_reserved, 0)
    if usable == 0:
        return None
    pct = max(0.0, min(100.0, (float(ips_avail) / float(usable)) * 100.0))
    return round(pct, 1)

def status_emoji(pct, green_th=60.0, orange_th=30.0):
    if pct is None:
        return "🔵"
    if pct >= green_th:
        return "🟢"
    if pct >= orange_th:
        return "🟠"
    return "🔴"

def make_summary(prefix_cidr, nb_subnets, ips_used, ips_avail, green_th, orange_th):
    pct = avail_pct(prefix_cidr, ips_avail)
    status = status_emoji(pct, green_th, orange_th)
    line = f"{status} | 🧩 Subnets: {fmt_int(nb_subnets)} | 🔴 Used: {fmt_int(ips_used)} | 🟢 Available: {fmt_int(ips_avail)}"
    if pct is not None:
        line += f" | ⚖️ {pct}%"
    return line

def find_col(fieldnames, candidates):
    lower = { (fn or "").strip().lower(): fn for fn in fieldnames }
    for c in candidates:
        if c in lower:
            return lower[c]
    return None

def ensure_cf(nb, cf_def):
    try:
        name = cf_def["name"]
        existing = list(nb.extras.custom_fields.filter(name=name))
        if existing:
            return existing[0]
        return nb.extras.custom_fields.create(cf_def)
    except Exception as e:
        print(f"[WARN] Could not ensure custom field '{cf_def.get('name')}': {e}", file=sys.stderr)
        return None

def ensure_tag(nb):
    try:
        found = list(nb.extras.tags.filter(slug=TAG_SLUG))
        if found:
            return found[0]
        return nb.extras.tags.create({"name": TAG_NAME, "slug": TAG_SLUG, "color": TAG_COLOR})
    except Exception as e:
        print(f"[WARN] Could not ensure tag '{TAG_NAME}': {e}", file=sys.stderr)
        return None

def main():
    ap = argparse.ArgumentParser(description="Update NetBox CFs from azure-vnet-scan CSV. Creates missing container prefixes if requested.")
    ap.add_argument("csv", help="CSV produced by azure-vnet-scan.sh")
    ap.add_argument("--green-th", type=float, default=None, help="🟢 threshold (%% available). Default: env AVAIL_GREEN_TH or 60")
    ap.add_argument("--orange-th", type=float, default=None, help="🟠 threshold (%% available). Default: env AVAIL_ORANGE_TH or 30")
    ap.add_argument("--strict-unique", action="store_true",
                    help="Update only when the prefix match is unique. Default: update all matches.")
    ap.add_argument("--create-missing", action="store_true",
                    help="Create container prefixes (global) when missing, tag with 'ip-availables-sync'.")
    ap.add_argument("--no-create-cf", action="store_true",
                    help="Do not try to create custom fields if they don't exist.")
    ap.add_argument("--dry-run", action="store_true", help="Print actions; do not write to NetBox.")
    args = ap.parse_args()

    NETBOX_URL = os.environ.get("NETBOX_URL")
    NETBOX_TOKEN = os.environ.get("NETBOX_TOKEN")
    if not NETBOX_URL or not NETBOX_TOKEN:
        print("Error: set NETBOX_URL and NETBOX_TOKEN environment variables.", file=sys.stderr)
        sys.exit(2)

    green_th = to_float(os.environ.get("AVAIL_GREEN_TH"), 60.0)
    orange_th = to_float(os.environ.get("AVAIL_ORANGE_TH"), 30.0)
    if args.green_th is not None:
        green_th = args.green_th
    if args.orange_th is not None:
        orange_th = args.orange_th
    if green_th < orange_th:
        print(f"[WARN] green-th ({green_th}) < orange-th ({orange_th}) -> swapping thresholds", file=sys.stderr)
        green_th, orange_th = orange_th, green_th

    nb = pynetbox.api(NETBOX_URL, token=NETBOX_TOKEN)

    if not args.no_create_cf:
        ensure_cf(nb, CF_SUMMARY_DEF)
        ensure_cf(nb, CF_USED_DEF)
        ensure_cf(nb, CF_AVAIL_DEF)
    if args.create_missing:
        ensure_tag(nb)

    with open(args.csv, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096); f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;")
        except Exception:
            dialect = csv.excel
        reader = csv.DictReader(f, dialect=dialect)

        cols = reader.fieldnames or []
        # Accept English or legacy French headers
        col_prefix = find_col(cols, {"address space","adresse space","prefix"})
        col_subnets = find_col(cols, {"subnets","nb subnets","nombre de subnets","nb_subnets"})
        col_used = find_col(cols, {"ips used","ips utilisées","ips utilisees","ips_used","used"})
        col_avail = find_col(cols, {"ips available","ips disponibles","ips disponible","ips_available","available"})
        if not all([col_prefix, col_subnets, col_used, col_avail]):
            print("[ERR] Missing columns. Expected: 'address space'/'prefix', 'subnets', 'ips used', 'ips available'", file=sys.stderr)
            print(f"      Detected headers: {cols}", file=sys.stderr)
            sys.exit(1)

        updated = skipped = multi = missing = created = 0

        for row in reader:
            prefix = (row.get(col_prefix) or "").strip()
            if not prefix:
                continue
            nb_subnets = to_int(row.get(col_subnets), 0)
            ips_used   = to_int(row.get(col_used), 0)
            ips_avail  = to_int(row.get(col_avail), 0)

            summary = make_summary(prefix, nb_subnets, ips_used, ips_avail, green_th, orange_th)

            matches = list(nb.ipam.prefixes.filter(prefix=prefix, limit=0))
            if not matches and args.create_missing:
                payload = {
                    "prefix": prefix,
                    "status": "container",
                    "description": CREATE_DESC,
                    "tags": [TAG_NAME],
                }
                if args.dry_run:
                    print(f"[DRY][CREATE] container prefix {prefix} (global) with tag '{TAG_NAME}'")
                else:
                    try:
                        newp = nb.ipam.prefixes.create(payload)
                        print(f"[CREATE] {prefix} (global) id={newp.id}")
                        matches = [newp]
                        created += 1
                    except Exception as e:
                        print(f"[ERR] Failed to create container prefix {prefix}: {e}", file=sys.stderr)

            if not matches:
                print(f"[MISS] Prefix not found in NetBox: {prefix}")
                missing += 1
                continue
            if args.strict_unique and len(matches) != 1:
                print(f"[SKIP] Non-unique prefix ({len(matches)} matches): {prefix}")
                skipped += 1
                continue

            for p in matches:
                cf = p.custom_fields or {}
                cf[CF_SUMMARY_NAME] = summary
                cf[CF_USED_NAME] = ips_used
                cf[CF_AVAIL_NAME] = ips_avail
                if args.dry_run:
                    print(f"[DRY][UPDATE] {prefix}: {summary} | {CF_USED_NAME}={ips_used} | {CF_AVAIL_NAME}={ips_avail}")
                else:
                    ok = p.update({"custom_fields": cf})
                    if ok:
                        print(f"[OK] Updated {prefix}")
                        updated += 1
                    else:
                        print(f"[ERR] Update failed for {prefix}", file=sys.stderr)
            if not args.strict_unique and len(matches) > 1:
                multi += 1

    print(f"\nSummary: updated={updated}, created={created}, skipped={skipped}, multi-prefixes={multi}, missing={missing}")

if __name__ == "__main__":
    main()
```

How to use

Dry-run:

```
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
python3 update_list_available_ips.py out.csv --create-missing --dry-run
```

Update custom fields (and create missing containers if needed):

```
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
python3 update_list_available_ips.py out.csv --create-missing
```

Custom availability thresholds (for the emoji color and %):

```
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
python3 update_list_available_ips.py out.csv --green-th 70 --orange-th 40
```

Notes

Field names (API keys): list_available_ips, ips_used, ips_available.
Labels shown in UI: “List available IPs”, “IP Used”, “IP Availables”.
No Tenant/VRF touched; created prefixes are global, status=container, tagged ip-availables-sync with a warning description.
The script accepts both English and French CSV headers, so you can keep your current scanner output.
