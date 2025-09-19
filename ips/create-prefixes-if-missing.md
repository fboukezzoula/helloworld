
- Never sets VRF or Tenant
- Force‑updates the custom field for all matches
- If a prefix is missing and you pass --create-missing, it creates a container prefix in the global scope (no VRF, no tenant), sets description to “⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC”, and tags it with ip-availables-sync (auto-created if missing)

Script (save as update_list_available_ips.py)

```python
#!/usr/bin/env python3
# Force-update NetBox CF "list_available_ips" (IPAM > Prefixes) from the CSV produced by azure-vnet-scan.sh.
# - No VRF or Tenant usage at all.
# - --create-missing: create container prefixes in GLOBAL scope (no VRF, no tenant),
#   set description to "⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC",
#   and tag them with "ip-availables-sync" (auto-created if missing).
# - Value format: "🟢 | 🧩 Subnets: N | 🔴 Used: U | 🟢 Available: A | ⚖️ P%"

import os, sys, csv, argparse, ipaddress
import pynetbox

CF_NAME = "list_available_ips"
CF_DEF = {
    "name": CF_NAME,
    "label": "List available IPs",
    "type": "text",
    "content_types": ["ipam.prefix"],
    "description": "Summary of used and available IPs in the prefix",
    "required": False,
}

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
        return None  # skip % for IPv6
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

def ensure_custom_field(nb):
    try:
        existing = list(nb.extras.custom_fields.filter(name=CF_NAME))
        if existing:
            return existing[0]
        return nb.extras.custom_fields.create(CF_DEF)
    except Exception as e:
        print(f"[WARN] Could not ensure custom field '{CF_NAME}': {e}", file=sys.stderr)
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
    ap = argparse.ArgumentParser(description="Force-update NetBox CF 'list_available_ips' from CSV. Optionally create missing container prefixes (global).")
    ap.add_argument("csv", help="CSV produced by azure-vnet-scan.sh")
    ap.add_argument("--green-th", type=float, default=None, help="🟢 threshold (%% available). Default: env AVAIL_GREEN_TH or 60")
    ap.add_argument("--orange-th", type=float, default=None, help="🟠 threshold (%% available). Default: env AVAIL_ORANGE_TH or 30")
    ap.add_argument("--strict-unique", action="store_true",
                    help="Update only when the prefix match is unique. Default: update all matches.")
    ap.add_argument("--create-missing", action="store_true",
                    help="Create container prefixes not found in NetBox (global scope) and tag with 'ip-availables-sync'.")
    ap.add_argument("--no-create-cf", action="store_true",
                    help="Do not try to create the custom field if it doesn't exist.")
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
        ensure_custom_field(nb)
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
                cf[CF_NAME] = summary
                if args.dry_run:
                    print(f"[DRY][UPDATE] {prefix}: {summary}")
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


Usage examples

Dry run (create missing in global, tag, and show updates):
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
```
python3 update_list_available_ips.py out.csv --create-missing --dry-run
```

Create missing container prefixes and update the custom field:
```
python3 update_list_available_ips.py out.csv --create-missing
```

NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx

```
python3 update_list_available_ips.py out.csv --green-th 70 --orange-th 40
```

Override the creation description text:

```
IP_SYNC_CREATE_DESC="⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC"
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
python3 update_list_available_ips.py out.csv --create-missing
```

This stays fully VRF/Tenant-agnostic and only touches the custom field and, optionally, creates global container prefixes with the tag you wanted.
