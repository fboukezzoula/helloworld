# Seuils configurables pour le statut couleur:

- 🟢 si disponibilité ≥ green_th (par défaut 60)
- 🟠 si disponibilité ≥ orange_th (par défaut 30)
- 🔴 sinon
- 🔵 si le % n’est pas calculable (IPv6)

# Les seuils peuvent être passés:

- en variables d’environnement: AVAIL_GREEN_TH, AVAIL_ORANGE_TH
- et/ou en arguments: --green-th, --orange-th

- S’il y a incohérence (green_th < orange_th), le script réordonne les seuils et affiche un avertissement.

```python
#!/usr/bin/env python3
# update_list_available_ips.py
# Force update du CF "list_available_ips" (IPAM > Prefixes) à partir du CSV azure-vnet-scan.sh.
# - Crée le CF s'il n'existe pas
# - Met à jour tous les préfixes correspondants (quel que soit le VRF)
# - Valeur: "🟢 | 🧩 Subnets: N | 🔴 Utilisées: U | 🟢 Disponibles: A | ⚖️ P%"

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

def avail_pct(prefix_cidr, ips_avail):
    try:
        net = ipaddress.ip_network(prefix_cidr, strict=False)
    except Exception:
        return None
    if net.version == 6:
        return None  # pas de % pour IPv6 (adapter si besoin: réserves=2)
    usable = max(net.num_addresses - 5, 0)
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
    line = f"{status} | 🧩 Subnets: {fmt_int(nb_subnets)} | 🔴 Utilisées: {fmt_int(ips_used)} | 🟢 Disponibles: {fmt_int(ips_avail)}"
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
        print(f"[WARN] Impossible de vérifier/créer le custom field '{CF_NAME}': {e}", file=sys.stderr)
        return None

def main():
    ap = argparse.ArgumentParser(description="Force update NetBox custom field 'list_available_ips' from CSV.")
    ap.add_argument("csv", help="CSV produit par azure-vnet-scan.sh")
    ap.add_argument("--green-th", type=float, default=None, help="Seuil 🟢 (%% dispo). Défaut: env AVAIL_GREEN_TH ou 60")
    ap.add_argument("--orange-th", type=float, default=None, help="Seuil 🟠 (%% dispo). Défaut: env AVAIL_ORANGE_TH ou 30")
    ap.add_argument("--strict-unique", action="store_true",
                    help="N'update que si le prefix est unique dans NetBox (sinon skip). Par défaut: met à jour tous les matchs.")
    ap.add_argument("--no-create-cf", action="store_true",
                    help="Ne pas tenter de créer le CF s'il n'existe pas.")
    ap.add_argument("--dry-run", action="store_true", help="N'écrit rien; affiche seulement.")
    args = ap.parse_args()

    NETBOX_URL = os.environ.get("NETBOX_URL")
    NETBOX_TOKEN = os.environ.get("NETBOX_TOKEN")
    if not NETBOX_URL or not NETBOX_TOKEN:
        print("Erreur: définis NETBOX_URL et NETBOX_TOKEN dans l'environnement.", file=sys.stderr)
        sys.exit(2)

    # Seuils depuis l'env puis override par CLI
    green_th = to_float(os.environ.get("AVAIL_GREEN_TH"), 60.0)
    orange_th = to_float(os.environ.get("AVAIL_ORANGE_TH"), 30.0)
    if args.green_th is not None:
        green_th = args.green_th
    if args.orange_th is not None:
        orange_th = args.orange_th
    # Normaliser l'ordre des seuils
    if green_th < orange_th:
        print(f"[WARN] green-th ({green_th}) < orange-th ({orange_th}) -> permutation des seuils", file=sys.stderr)
        green_th, orange_th = orange_th, green_th

    nb = pynetbox.api(NETBOX_URL, token=NETBOX_TOKEN)

    if not args.no_create_cf:
        ensure_custom_field(nb)

    with open(args.csv, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096); f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;")
        except Exception:
            dialect = csv.excel
        reader = csv.DictReader(f, dialect=dialect)

        cols = reader.fieldnames or []
        col_prefix = find_col(cols, {"adresse space","address space","prefix"})
        col_subnets = find_col(cols, {"nb subnets","subnets","nombre de subnets","nb_subnets"})
        col_used = find_col(cols, {"ips utilisées","ips utilisees","ips used","ips_used","used"})
        col_avail = find_col(cols, {"ips disponibles","ips disponible","ips available","ips_available","available"})
        if not all([col_prefix, col_subnets, col_used, col_avail]):
            print("[ERR] Colonnes manquantes. Attendu: 'adresse space'/'prefix', 'nb subnets', 'ips utilisées', 'ips disponibles'", file=sys.stderr)
            print(f"      Entêtes détectées: {cols}", file=sys.stderr)
            sys.exit(1)

        updated = skipped = multi = missing = 0

        for row in reader:
            prefix = (row.get(col_prefix) or "").strip()
            if not prefix:
                continue
            nb_subnets = to_int(row.get(col_subnets), 0)
            ips_used   = to_int(row.get(col_used), 0)
            ips_avail  = to_int(row.get(col_avail), 0)

            summary = make_summary(prefix, nb_subnets, ips_used, ips_avail, green_th, orange_th)

            matches = list(nb.ipam.prefixes.filter(prefix=prefix, limit=0))
            if not matches:
                print(f"[MISS] Prefix absent de NetBox: {prefix}")
                missing += 1
                continue
            if args.strict_unique and len(matches) != 1:
                print(f"[SKIP] Prefix non-unique ({len(matches)} matchs): {prefix}")
                skipped += 1
                continue

            for p in matches:
                cf = p.custom_fields or {}
                cf[CF_NAME] = summary
                if args.dry_run:
                    print(f"[DRY] {prefix} (vrf={p.vrf.name if p.vrf else 'global'}): {summary}")
                else:
                    ok = p.update({"custom_fields": cf})
                    if ok:
                        print(f"[OK] {prefix} (vrf={p.vrf.name if p.vrf else 'global'}) mis à jour")
                        updated += 1
                    else:
                        print(f"[ERR] Echec update pour {prefix}", file=sys.stderr)
            if not args.strict_unique and len(matches) > 1:
                multi += 1

    print(f"\nRésumé: updated={updated}, skipped={skipped}, multi-prefixes={multi}, missing={missing}")

if __name__ == "__main__":
    main()
```

# Exemples

- Par défaut (🟢 ≥ 60, 🟠 ≥ 30):

```python3 update_list_available_ips.py out.csv```

- Seuils personnalisés: 🟢 ≥ 70, 🟠 ≥ 40

```python3 update_list_available_ips.py out.csv --green-th 70 --orange-th 40```

- Via variables d’environnement:

```AVAIL_GREEN_TH=75 AVAIL_ORANGE_TH=50 python3 update_list_available_ips.py out.csv```

- Test sans écrire:

```python3 update_list_available_ips.py out.csv --dry-run```
