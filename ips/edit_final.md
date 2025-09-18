# Compute used/avail AND the number of subnets within an address space
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
    print("0 0 0"); sys.exit(0)
if net.version==6 and not enable_v6:
    print("0 0 0"); sys.exit(0)

used_total=0
avail_total=0
seen_subnets=set()

for p in pairs:
    sid=""; cidr_str=""; used_str=""
    if "|||" in p:
        try:
            sid, cidr_str, used_str = p.split("|||", 2)
        except Exception:
            continue
    else:
        # backward compatibility: "cidr,used"
        try:
            cidr_str, used_str = p.split(",", 1)
        except Exception:
            continue
    try:
        used=int(used_str)
        sn=ipaddress.ip_network(cidr_str.strip(), strict=False)
    except Exception:
        continue
    if sn.version!=net.version or not sn.subnet_of(net):
        continue

    reserved = 5 if sn.version==4 else 2
    avail = max(sn.num_addresses - reserved - used, 0)
    used_total += used
    avail_total += avail

    # count unique subnets in this space (by subnet ID if provided, else by CIDR)
    seen_subnets.add(sid or cidr_str)

print(f"{used_total} {avail_total} {len(seen_subnets)}")
PY
}


# Build "sid|||cidr|||used" per subnet prefix
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


res="$(compute_used_and_avail_for_prefix "$prefix" "${pairs_for_calc[@]}")"
read -r ips_used ips_avail subnets_in_space <<< "$res"
log DEBUG "  Prefix $prefix -> Subnets: $subnets_in_space, IPs used: $ips_used, available: $ips_avail"
echo "\"$mg_name\",\"$sub_id\",\"$sub_name\",\"$vnet_name\",\"$prefix\",\"$subnets_in_space\",\"$ips_used\",\"$ips_avail\",\"$location\"" >> "$OUTFILE"
