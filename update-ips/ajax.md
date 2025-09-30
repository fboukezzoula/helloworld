
CSV format (the “update feed” the updater consumes)
# Your updater now accepts your scanner CSV plus an extra column netbox_prefix_id. The header can be:

- management group
- subscription id
- subscription name
- vnet name
- address space
- subnets
- ips used
- ips available
- region
- netbox_prefix_id

## Only these four columns are strictly required by the updater:

- address space (or prefix)
- subnets
- ips used
- ips available
- Optional but recommended: netbox_prefix_id
- Sample file: update_list_available_ip.csv

```csv
management group,subscription id,subscription name,vnet name,address space,subnets,ips used,ips available,region,netbox_prefix_id
N/A,11111111-2222-3333-4444-555555555555,Sub-Prod,vnet-hub,192.245.229.0/24,9,84,147,westeurope,1234
N/A,11111111-2222-3333-4444-555555555555,Sub-Prod,vnet-hub,10.125.133.0/24,3,12,239,westeurope,5678
N/A,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,Sub-Dev,vnet-dev,10.10.0.0/16,12,210,40426,francecentral,
```

## Notes

- If netbox_prefix_id is present and numeric, the updater uses it to update that exact prefix.
- If netbox_prefix_id is empty, it falls back to matching by CIDR (address space/prefix).
- You can keep all the other columns—they’re ignored for matching but useful for audit.
- Full updater (uses netbox_prefix_id if present, preserves all existing tags, enforces ip-availables-sync)
- Save as update_list_available_ips.py

```python
#!/usr/bin/env python3
# Update NetBox custom fields from CSV (emoji summary + numeric fields) and
# ALWAYS add the 'ip-availables-sync' tag, preserving all existing tags.
# If 'netbox_prefix_id' is present in CSV, update by ID; else, match by CIDR.

import os, sys, csv, argparse, ipaddress
import pynetbox

# --- Custom fields definitions ---
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

# --- Tag (always enforced) ---
TAG_NAME = "ip-availables-sync"
TAG_SLUG = "ip-availables-sync"
TAG_COLOR = "teal"
CREATE_DESC = os.environ.get("IP_SYNC_CREATE_DESC", "⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC")

# --- Helpers ---
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
        return None
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

def extract_tag_ids_from_obj(nb, tags):
    """Extract numeric tag IDs from an object's 'tags' field (dicts/ids/strings)."""
    ids = set()
    for t in (tags or []):
        if isinstance(t, dict):
            if t.get("id"):
                ids.add(t["id"])
            elif t.get("slug"):
                m = list(nb.extras.tags.filter(slug=t["slug"]))
                if m: ids.add(m[0].id)
            elif t.get("name"):
                m = list(nb.extras.tags.filter(name=t["name"]))
                if m: ids.add(m[0].id)
        elif isinstance(t, int):
            ids.add(t)
        elif isinstance(t, str):
            m = list(nb.extras.tags.filter(name=t)) or list(nb.extras.tags.filter(slug=t))
            if m: ids.add(m[0].id)
    return ids

def get_existing_tag_ids(nb, prefix_obj):
    """Fetch a fresh copy of the prefix to reliably read tag IDs, with a robust fallback."""
    try:
        fresh = nb.ipam.prefixes.get(prefix_obj.id)
        if fresh and hasattr(fresh, "tags"):
            ids = {t.get("id") for t in (fresh.tags or []) if isinstance(t, dict) and t.get("id")}
            if ids:
                return ids
            return extract_tag_ids_from_obj(nb, fresh.tags)
    except Exception:
        pass
    return extract_tag_ids_from_obj(nb, getattr(prefix_obj, "tags", []))

def iter_matches(nb, prefix):
    try:
        for obj in nb.ipam.prefixes.filter(prefix=prefix):
            yield obj
    except Exception as e:
        print(f"[ERR] Query failed for prefix={prefix}: {e}", file=sys.stderr)

# --- Main ---
def main():
    ap = argparse.ArgumentParser(description="Update NetBox CFs from CSV. Preserve tags and add 'ip-availables-sync' by ID. Use netbox_prefix_id if present.")
    ap.add_argument("csv", help="CSV produced by azure-vnet-scan.sh (optionally annotated with netbox_prefix_id)")
    ap.add_argument("--green-th", type=float, default=None, help="🟢 threshold (%% available). Default: env AVAIL_GREEN_TH or 60")
    ap.add_argument("--orange-th", type=float, default=None, help="🟠 threshold (%% available). Default: env AVAIL_ORANGE_TH or 30")
    ap.add_argument("--strict-unique", action="store_true",
                    help="Update only when the prefix match is unique (ignored when ID is present).")
    ap.add_argument("--create-missing", action="store_true",
                    help="Create container prefixes (global) when missing and tag them.")
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

    # Ensure CFs (unless disabled) and tag up front
    if not args.no_create_cf:
        ensure_cf(nb, CF_SUMMARY_DEF)
        ensure_cf(nb, CF_USED_DEF)
        ensure_cf(nb, CF_AVAIL_DEF)
    tag_obj = ensure_tag(nb)
    tag_id = getattr(tag_obj, "id", None)

    with open(args.csv, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096); f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;")
        except Exception:
            dialect = csv.excel
        reader = csv.DictReader(f, dialect=dialect)

        cols = reader.fieldnames or []
        # Required columns + optional netbox_prefix_id
        col_prefix = find_col(cols, {"address space","adresse space","prefix"})
        col_subnets = find_col(cols, {"subnets","nb subnets","nombre de subnets","nb_subnets"})
        col_used = find_col(cols, {"ips used","ips utilisées","ips utilisees","ips_used","used"})
        col_avail = find_col(cols, {"ips available","ips disponibles","ips disponible","ips_available","available"})
        col_id = find_col(cols, {"netbox_prefix_id","netbox prefix id"})
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

            # Resolve matches: prefer exact ID if present
            matches = []
            if col_id:
                id_val = (row.get(col_id) or "").strip()
                if id_val.isdigit():
                    try:
                        obj = nb.ipam.prefixes.get(int(id_val))
                        if obj:
                            matches = [obj]
                    except Exception as e:
                        print(f"[ERR] Lookup by ID failed for {prefix} (id={id_val}): {e}", file=sys.stderr)
            if not matches:
                matches = [obj for obj in iter_matches(nb, prefix)]

            if not matches and args.create_missing:
                payload = {
                    "prefix": prefix,
                    "status": "container",
                    "description": CREATE_DESC,
                    "tags": ([tag_id] if tag_id else []),
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
                # Preserve ALL existing tag IDs, then add our tag ID
                existing_ids = get_existing_tag_ids(nb, p)
                if tag_id:
                    existing_ids.add(tag_id)
                tags_payload = sorted(existing_ids)

                cf = p.custom_fields or {}
                cf[CF_SUMMARY_NAME] = summary
                cf[CF_USED_NAME] = ips_used
                cf[CF_AVAIL_NAME] = ips_avail

                if args.dry_run:
                    print(f"[DRY][UPDATE] {prefix}: tag_ids={tags_payload} | {CF_SUMMARY_NAME}='{summary}' | {CF_USED_NAME}={ips_used} | {CF_AVAIL_NAME}={ips_avail}")
                else:
                    try:
                        ok = p.update({"custom_fields": cf, "tags": tags_payload})
                        if ok:
                            print(f"[OK] Updated {prefix} (preserved {len(tags_payload)} tag IDs)")
                            updated += 1
                        else:
                            print(f"[ERR] Update failed for {prefix}", file=sys.stderr)
                    except Exception as e:
                        err_text = getattr(e, "error", None) or getattr(e, "args", [""])[0]
                        print(f"[ERR] Update exception for {prefix}: {err_text}", file=sys.stderr)

            if not args.strict_unique and len(matches) > 1:
                multi += 1

    print(f"\nSummary: updated={updated}, created={created}, skipped={skipped}, multi-prefixes={multi}, missing={missing}")

if __name__ == "__main__":
    main()
```


## How to run

- Dry run (see the tag IDs union and values to be written):
- NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
```
python3 update_list_available_ips.py update_list_available_ip.csv --dry-run
```
### Live update (create missing containers if needed):
```
NETBOX_URL=https://netbox.example.com NETBOX_TOKEN=xxx
python3 update_list_available_ips.py update_list_available_ip.csv --create-missing
```
### Custom availability thresholds for the emoji color and %:
```
NETBOX_URL=... NETBOX_TOKEN=...
python3 update_list_available_ips.py update_list_available_ip.csv --green-th 70 --orange-th 40
