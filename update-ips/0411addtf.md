Objectif

- Si un VNet Azure porte le tag status=Managed by Terraform:

  - le CSV du scanner ajoute une colonne automation = "Managed by Terraform" pour chaque address space de ce VNet.
  - l’updater NetBox écrit le custom field Prefix “automation” avec cette valeur.
  - en option: on ajoute aussi le tag NetBox “TERRAFORM” (ID=60) sur le préfixe.

1. Patch du scanner azure-vnet-scan.sh
Ajoute ces variables (près des autres variables d’env en tête du script):

```bash
# Automation tag detection (Azure VNet)
# Azure VNet tag key/value to detect Terraform-managed VNets
AUTOMATION_TAG_KEY="${VNET_AUTOMATION_TAG_KEY:-status}"
AUTOMATION_TAG_VALUE="${VNET_AUTOMATION_TAG_VALUE:-Managed by Terraform}"
```

Modifie l’entête CSV (on ajoute la colonne “automation” à la fin):

```bash
echo "management group,subscription id,subscription name,vnet name,address space,subnets,ips used,ips available,region,automation" > "$OUTFILE"
```

Dans la boucle VNet (juste après avoir extrait vnet_name/location), calcule la valeur “automation” depuis les tags Azure:

```bash
# Azure VNet tags -> automation value
automation_out=""
automation_status=$(echo "$vnet" | jq -r --arg k "$AUTOMATION_TAG_KEY" '.tags?[$k] // empty')
if [[ "$automation_status" == "$AUTOMATION_TAG_VALUE" ]]; then
  automation_out="$AUTOMATION_TAG_VALUE"
fi
```

Lors de l’écriture de chaque ligne CSV (par address space), ajoute la colonne “automation”:

```bash
printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
  "$(csvq "${mg_name}")" \
  "$(csvq "${sub_id}")" \
  "$(csvq "${sub_name}")" \
  "$(csvq "${vnet_name}")" \
  "$(csvq "${prefix}")" \
  "$(csvq "${subnets_in_space}")" \
  "$(csvq "${ips_used}")" \
  "$(csvq "${ips_avail}")" \
  "$(csvq "${location}")" \
  "$(csvq "${automation_out}")" >> "$OUTFILE"
```

Notes

- Par défaut on cherche le tag Azure status=Managed by Terraform. Tu peux changer la clé/valeur via:
  - VNET_AUTOMATION_TAG_KEY (par défaut status)
  - VNET_AUTOMATION_TAG_VALUE (par défaut Managed by Terraform)

2. Patch de l’updater update_list_available_ips.py
- Assure le custom field Prefix “automation” (type text).
- Lit la colonne automation du CSV.
- Si la valeur vaut “Managed by Terraform”, écrit le CF automation et ajoute le tag NetBox TERRAFORM (ID=60) sur le préfixe.
- Préserve les tags existants et continue d’ajouter ip-availables-sync.

Remplace ton script par celui-ci (version complète, compatible netbox_prefix_id):

```python
#!/usr/bin/env python3
# Update NetBox CFs from CSV; preserve all tags and add:
# - 'ip-availables-sync' tag (always)
# - 'TERRAFORM' tag (ID configurable) if automation == "Managed by Terraform"
# Writes CFs: list_available_ips (emoji summary), ips_used, ips_available, automation (text).

import os, sys, csv, argparse, ipaddress
import pynetbox

# --- CF names ---
CF_SUMMARY_NAME = "list_available_ips"
CF_USED_NAME    = "ips_used"
CF_AVAIL_NAME   = "ips_available"
CF_AUTO_NAME    = "automation"

CF_SUMMARY_DEF = {
    "name": CF_SUMMARY_NAME, "label": "List available IPs", "type": "text",
    "content_types": ["ipam.prefix"], "description": "Summary of used and available IPs in the prefix", "required": False,
}
CF_USED_DEF = {
    "name": CF_USED_NAME, "label": "IP Used", "type": "integer",
    "content_types": ["ipam.prefix"], "description": "Number of IP addresses used in the prefix", "required": False,
}
CF_AVAIL_DEF = {
    "name": CF_AVAIL_NAME, "label": "IP Availables", "type": "integer",
    "content_types": ["ipam.prefix"], "description": "Number of IP addresses available in the prefix", "required": False,
}
CF_AUTO_DEF = {
    "name": CF_AUTO_NAME, "label": "Automation", "type": "text",
    "content_types": ["ipam.prefix"], "description": "Automation source/status for this prefix", "required": False,
}

# --- Tags ---
SYNC_TAG_NAME = "ip-availables-sync"
SYNC_TAG_SLUG = "ip-availables-sync"
SYNC_TAG_COLOR = "teal"

# Terraform tag (numeric ID known/created by you)
TERRAFORM_TAG_ID = int(os.environ.get("TERRAFORM_TAG_ID", "60"))  # you said ID=60

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
    try: n = int(n)
    except Exception: return "0"
    return f"{n:,}".replace(",", " ")

def avail_pct(prefix_cidr, ips_avail, ipv4_reserved=5):
    try: net = ipaddress.ip_network(prefix_cidr, strict=False)
    except Exception: return None
    if net.version == 6: return None
    usable = max(net.num_addresses - ipv4_reserved, 0)
    if usable == 0: return None
    pct = max(0.0, min(100.0, (float(ips_avail) / float(usable)) * 100.0))
    return round(pct, 1)

def status_emoji(pct, green_th=60.0, orange_th=30.0):
    if pct is None: return "🔵"
    if pct >= green_th: return "🟢"
    if pct >= orange_th: return "🟠"
    return "🔴"

def make_summary(prefix_cidr, nb_subnets, ips_used, ips_avail, green_th, orange_th):
    pct = avail_pct(prefix_cidr, ips_avail)
    status = status_emoji(pct, green_th, orange_th)
    line = f"{status} | 🧩 Subnets: {fmt_int(nb_subnets)} | 🔴 Used: {fmt_int(ips_used)} | 🟢 Available: {fmt_int(ips_avail)}"
    if pct is not None:
        line += f" | ⚖️ {pct}%"
    return line

def find_col(fieldnames, candidates):
    lower = {(fn or "").strip().lower(): fn for fn in fieldnames}
    for c in candidates:
        if c in lower: return lower[c]
    return None

def ensure_cf(nb, cf_def):
    try:
        name = cf_def["name"]
        if list(nb.extras.custom_fields.filter(name=name)): return
        nb.extras.custom_fields.create(cf_def)
    except Exception as e:
        print(f"[WARN] ensure_cf {cf_def.get('name')}: {e}", file=sys.stderr)

def ensure_sync_tag(nb):
    try:
        found = list(nb.extras.tags.filter(slug=SYNC_TAG_SLUG))
        return found[0] if found else nb.extras.tags.create({"name": SYNC_TAG_NAME, "slug": SYNC_TAG_SLUG, "color": SYNC_TAG_COLOR})
    except Exception as e:
        print(f"[WARN] ensure_tag {SYNC_TAG_SLUG}: {e}", file=sys.stderr)
        return None

def normalize_tag_to_id(t):
    if hasattr(t, "id") and isinstance(getattr(t, "id"), int):
        return int(getattr(t, "id"))
    if isinstance(t, dict) and isinstance(t.get("id"), int):
        return int(t["id"])
    if isinstance(t, int): return t
    return None  # strings are not acceptable on write for NetBox 4.x

def get_existing_tag_ids(nb, prefix_obj):
    try:
        fresh = nb.ipam.prefixes.get(prefix_obj.id)
        tags_src = getattr(fresh, "tags", None)
    except Exception:
        tags_src = getattr(prefix_obj, "tags", None)
    ids = set()
    for t in (tags_src or []):
        tid = normalize_tag_to_id(t)
        if tid is not None:
            ids.add(tid)
    return ids

def iter_matches(nb, prefix):
    try:
        for obj in nb.ipam.prefixes.filter(prefix=prefix):
            yield obj
    except Exception as e:
        print(f"[ERR] Query failed for prefix={prefix}: {e}", file=sys.stderr)

# --- Main ---
def main():
    ap = argparse.ArgumentParser(description="Update NetBox CFs from CSV; preserve all tags and add sync/terraform tags when applicable.")
    ap.add_argument("csv", help="CSV (supports netbox_prefix_id column and 'automation' column)")
    ap.add_argument("--green-th", type=float, default=None, help="🟢 threshold (%% available). Default env AVAIL_GREEN_TH or 60")
    ap.add_argument("--orange-th", type=float, default=None, help="🟠 threshold (%% available). Default env AVAIL_ORANGE_TH or 30")
    ap.add_argument("--strict-unique", action="store_true", help="Update only if match is unique (ignored when ID present).")
    ap.add_argument("--create-missing", action="store_true", help="Create container prefixes (global) when missing and tag them.")
    ap.add_argument("--no-create-cf", action="store_true", help="Do not create CFs if missing.")
    ap.add_argument("--dry-run", action="store_true", help="Print actions; do not write.")
    args = ap.parse_args()

    NETBOX_URL = os.environ.get("NETBOX_URL")
    NETBOX_TOKEN = os.environ.get("NETBOX_TOKEN")
    if not NETBOX_URL or not NETBOX_TOKEN:
        print("Error: set NETBOX_URL and NETBOX_TOKEN", file=sys.stderr); sys.exit(2)

    green_th = to_float(os.environ.get("AVAIL_GREEN_TH"), 60.0)
    orange_th = to_float(os.environ.get("AVAIL_ORANGE_TH"), 30.0)
    if args.green_th is not None: green_th = args.green_th
    if args.orange_th is not None: orange_th = args.orange_th
    if green_th < orange_th:
        print(f"[WARN] green-th ({green_th}) < orange-th ({orange_th}) -> swapping", file=sys.stderr)
        green_th, orange_th = orange_th, green_th

    nb = pynetbox.api(NETBOX_URL, token=NETBOX_TOKEN)

    if not args.no_create_cf:
        ensure_cf(nb, CF_SUMMARY_DEF)
        ensure_cf(nb, CF_USED_DEF)
        ensure_cf(nb, CF_AVAIL_DEF)
        ensure_cf(nb, CF_AUTO_DEF)
    sync_tag_obj = ensure_sync_tag(nb)
    sync_tag_id = getattr(sync_tag_obj, "id", None)

    with open(args.csv, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096); f.seek(0)
        try: dialect = csv.Sniffer().sniff(sample, delimiters=",;")
        except Exception: dialect = csv.excel
        reader = csv.DictReader(f, dialect=dialect)

        cols = reader.fieldnames or []
        col_prefix = find_col(cols, {"address space","adresse space","prefix"})
        col_subnets = find_col(cols, {"subnets","nb subnets","nombre de subnets","nb_subnets"})
        col_used    = find_col(cols, {"ips used","ips utilisées","ips utilisees","ips_used","used"})
        col_avail   = find_col(cols, {"ips available","ips disponibles","ips disponible","ips_available","available"})
        col_id      = find_col(cols, {"netbox_prefix_id","netbox prefix id"})
        col_auto    = find_col(cols, {"automation","automation status","terraform","tf_status"})
        if not all([col_prefix, col_subnets, col_used, col_avail]):
            print("[ERR] Missing columns. Need: 'address space'/'prefix', 'subnets', 'ips used', 'ips available'", file=sys.stderr)
            print("Headers:", cols, file=sys.stderr); sys.exit(1)

        updated = skipped = multi = missing = created = 0

        for row in reader:
            prefix = (row.get(col_prefix) or "").strip()
            if not prefix: continue
            nb_subnets = to_int(row.get(col_subnets), 0)
            ips_used   = to_int(row.get(col_used), 0)
            ips_avail  = to_int(row.get(col_avail), 0)
            auto_val   = (row.get(col_auto) or "").strip() if col_auto else ""

            summary = make_summary(prefix, nb_subnets, ips_used, ips_avail, green_th, orange_th)

            # Resolve: prefer ID if present
            matches = []
            if col_id:
                id_val = (row.get(col_id) or "").strip()
                if id_val.isdigit():
                    try:
                        obj = nb.ipam.prefixes.get(int(id_val))
                        if obj: matches = [obj]
                    except Exception as e:
                        print(f"[ERR] Lookup by ID failed for {prefix} (id={id_val}): {e}", file=sys.stderr)
            if not matches:
                matches = [obj for obj in iter_matches(nb, prefix)]

            if not matches and args.create_missin g:
                payload = {"prefix": prefix, "status": "container", "description": os.environ.get("IP_SYNC_CREATE_DESC", "⚠️ PREFIX CREATED BY IP AVAILABILITY SYNC")}
                if sync_tag_id is not None:
                    payload["tags"] = [sync_tag_id]
                if args.dry_run:
                    print(f"[DRY][CREATE] container {prefix} with sync tag id={sync_tag_id}")
                else:
                    try:
                        newp = nb.ipam.prefixes.create(payload)
                        print(f"[CREATE] {prefix} id={newp.id}")
                        matches = [newp]; created += 1
                    except Exception as e:
                        print(f"[ERR] Create failed for {prefix}: {e}", file=sys.stderr)

            if not matches:
                print(f"[MISS] Prefix not found in NetBox: {prefix}"); missing += 1; continue
            if args.strict_unique and len(matches) != 1:
                print(f"[SKIP] Non-unique ({len(matches)}) for {prefix}"); skipped += 1; continue

            for p in matches:
                # Preserve tag IDs, add sync tag, and optionally Terraform tag
                existing_ids = get_existing_tag_ids(nb, p)
                if sync_tag_id is not None:
                    existing_ids.add(sync_tag_id)
                if auto_val.lower() == "managed by terraform".lower() and TERRAFORM_TAG_ID > 0:
                    existing_ids.add(TERRAFORM_TAG_ID)
                tags_payload = sorted(existing_ids)

                # CFs
                cf = p.custom_fields or {}
                cf[CF_SUMMARY_NAME] = summary
                cf[CF_USED_NAME]    = ips_used
                cf[CF_AVAIL_NAME]   = ips_avail
                if auto_val:
                    cf[CF_AUTO_NAME] = auto_val  # n’écrase que si fourni

                if args.dry_run:
                    kept = [tid for tid in tags_payload if tid not in ({sync_tag_id, TERRAFORM_TAG_ID} - {None})]
                    info = f"keep_tag_ids={kept} + sync_id={sync_tag_id}"
                    if auto_val:
                        info += f" + terraform_id={TERRAFORM_TAG_ID}"
                    print(f"[DRY][UPDATE] {prefix}: {info} | {CF_SUMMARY_NAME}='{summary}' | {CF_USED_NAME}={ips_used} | {CF_AVAIL_NAME}={ips_avail}" + (f" | {CF_AUTO_NAME}='{auto_val}'" if auto_val else ""))
                    continue

                try:
                    ok = p.update({"custom_fields": cf, "tags": tags_payload})
                    if ok:
                        print(f"[OK] Updated {prefix} (tags preserved; sync tag ensured{' + terraform tag' if auto_val else ''})")
                        updated += 1
                    else:
                        print(f"[ERR] Update failed for {prefix}", file=sys.stderr)
                except Exception as e:
                    print(f"[ERR] Update exception for {prefix}: {getattr(e, 'error', None) or e}", file=sys.stderr)

            if not args.strict_unique and len(matches) > 1:
                multi += 1

    print(f"\nSummary: updated={updated}, created={created}, skipped={skipped}, multi-prefixes={multi}, missing={missing}")

if __name__ == "__main__":
    main()
```    
    
Points importants

- Le scanner ajoute “automation” dans out.csv si le VNet a le tag status=Managed by Terraform (clé/val configurable via VNET_AUTOMATION_TAG_KEY / VNET_AUTOMATION_TAG_VALUE).
- L’updater:
  - crée/assure le CF “automation”,
  - si la colonne automation du CSV vaut “Managed by Terraform”, écrit ce CF et ajoute le tag NetBox TERRAFORM (ID=60 par défaut, override via TERRAFORM_TAG_ID).
  - préserve tous les tags existants et continue d’ajouter ip-availables-sync.

Exemples

- Scanner:
  - SKIP_MG=1 ./azure-vnet-scan.sh -a -o out.csv -v
- Updater (dry-run):
  - NETBOX_URL=... NETBOX_TOKEN=... python3 update_list_available_ips.py out.csv --dry-run
- Updater (live, avec création des conteneurs si besoin):
  - NETBOX_URL=... NETBOX_TOKEN=... python3 update_list_available_ips.py out.csv --create-missing










  
