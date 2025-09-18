#!/usr/bin/env python3
# update_list_available_ips.py
# Met à jour le CF "list_available_ips" (IPAM > Prefixes) à partir du CSV de azure-vnet-scan.sh.

import os, sys, csv, argparse, ipaddress
import pynetbox

def to_int(s, default=0):
    try:
        s = (s or "").replace(" ", "").replace(",", "")
        return int(float(s)) if s else default
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
        return None  # pas de % pour IPv6
    usable = max(net.num_addresses - 5, 0)
    if usable == 0:
        return None
    pct = max(0.0, min(100.0, (float(ips_avail) / float(usable)) * 100.0))
    return round(pct, 1)

def make_summary(prefix_cidr, nb_subnets, ips_used, ips_avail):
    line = f"🧩 Subnets: {fmt_int(nb_subnets)} | 🔴 Utilisées: {fmt_int(ips_used)} | 🟢 Disponibles: {fmt_int(ips_avail)}"
    pct = avail_pct(prefix_cidr, ips_avail)
    if pct is not None:
        line += f" | ⚖️ {pct}%"
    return line

def find_col(fieldnames, candidates):
    lower = { (fn or "").strip().lower(): fn for fn in fieldnames }
    for c in candidates:
        if c in lower:
            return lower[c]
    return None

def main():
    ap = argparse.ArgumentParser(description="Update NetBox custom field 'list_available_ips' from CSV.")
    ap.add_argument("csv", help="CSV produit par azure-vnet-scan.sh")
    ap.add_argument("--strict-unique", action="store_true",
                    help="N'update que si le prefix est unique dans NetBox (sinon skip). Par défaut: met à jour tous les matchs.")
    ap.add_argument("--dry-run", action="store_true", help="N'écrit rien dans NetBox; affiche ce qui serait fait.")
    args = ap.parse_args()

    NETBOX_URL = os.environ.get("NETBOX_URL")
    NETBOX_TOKEN = os.environ.get("NETBOX_TOKEN")
    if not NETBOX_URL or not NETBOX_TOKEN:
        print("Erreur: définis NETBOX_URL et NETBOX_TOKEN dans l'environnement.", file=sys.stderr)
        sys.exit(2)

    nb = pynetbox.api(NETBOX_URL, token=NETBOX_TOKEN)

    # Ouverture CSV (détecte , ou ;)
    with open(args.csv, "r", encoding="utf-8-sig", newline="") as f:
        sample = f.read(4096)
        f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;")
        except Exception:
            dialect = csv.excel
        reader = csv.DictReader(f, dialect=dialect)

        # Détection souple des colonnes
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

            summary = make_summary(prefix, nb_subnets, ips_used, ips_avail)

            matches = list(nb.ipam.prefixes.filter(prefix=prefix))
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
                cf["list_available_ips"] = summary
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
