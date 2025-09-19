Good eye — by design we were only summing availability from subnets. If an address space has zero subnets, that yielded 0. If you want the CSV to show the theoretical available pool for an empty address space (e.g., /24 → 256 − 5 = 251), here’s a small patch.

What it does

1. If an address space contains no subnets:
IPv4: available = net_size − 5 (used = 0).
IPv6: available = net_size − 2 if ENABLE_IPV6=1, else 0.
Controlled by env var INCLUDE_EMPTY_SPACE (default 1). Set INCLUDE_EMPTY_SPACE=0 to revert to the old behavior.
Patch to your safe-copy script

2. Ensure this env var note is near the top (optional):
INCLUDE_EMPTY_SPACE=1 is the default if not set.
Replace your compute_used_and_avail_for_prefix with this version
It already returns: used_total avail_total subnets_in_space.
It detects the “no subnets” case and applies the rule above.

```python
# Compute used/avail AND number of subnets inside an address space.
# For empty address spaces: if INCLUDE_EMPTY_SPACE=1 (default), treat availability as net_size - reserved.
compute_used_and_avail_for_prefix() {
  local prefix="$1"; shift
  local enable_v6="${ENABLE_IPV6:-0}"
  local pairs=("$@")
  ENABLE_V6_ARG="$enable_v6" python3 - "$prefix" "$enable_v6" "${pairs[@]}" <<'PY'
import sys, os, ipaddress
prefix = sys.argv[1]
enable_v6 = sys.argv[2] == "1"
pairs = sys.argv[3:]
include_empty = os.environ.get("INCLUDE_EMPTY_SPACE", "1") == "1"

try:
    net = ipaddress.ip_network(prefix, strict=False)
except Exception:
    print("0 0 0"); sys.exit(0)

if net.version == 6 and not enable_v6:
    print("0 0 0"); sys.exit(0)

used_total = 0
avail_total = 0
seen_subnets = set()

for p in pairs:
    sid = ""; cidr_str = ""; used_str = ""
    if "|||" in p:
        parts = p.split("|||", 2)
        if len(parts) != 3:
            continue
        sid, cidr_str, used_str = parts
    else:
        parts2 = p.split(",", 1)
        if len(parts2) != 2:
            continue
        cidr_str, used_str = parts2

    try:
        used = int(used_str)
        sn = ipaddress.ip_network(cidr_str.strip(), strict=False)
    except Exception:
        continue

    if sn.version != net.version or not sn.subnet_of(net):
        continue

    reserved = 5 if sn.version == 4 else 2
    avail = sn.num_addresses - reserved - used
    if avail < 0:
        avail = 0
    used_total += used
    avail_total += avail
    seen_subnets.add(sid or cidr_str)

sub_count = len(seen_subnets)

# If no subnets exist in this address space, optionally report theoretical availability.
if sub_count == 0 and include_empty:
    if net.version == 4:
        avail_total = max(net.num_addresses - 5, 0)
        used_total = 0
    elif enable_v6:
        avail_total = max(net.num_addresses - 2, 0)
        used_total = 0

print(f"{used_total} {avail_total} {sub_count}")
PY
}
```

3. No other changes needed
You already build pairs_for_calc as sid|||cidr|||used and read “used avail subnets_in_space” from the function.
Your CSV will now show, for an empty address space: subnets=0, used=0, available=net_size−reserved (e.g., 251 for /24).
Example

Address space 10.194.12.0/24 with no subnets:
Before: subnets 0, used 0, available 0
After: subnets 0, used 0, available 251
Note

This is a “theoretical capacity” in the address space (what you could use by creating a subnet). If you prefer the original “only subnets count” behavior for some runs, you can disable it:
INCLUDE_EMPTY_SPACE=0 ./azure-vnet-scan.sh ...
If you later want to also include the leftover free gaps when an address space has some (but not all) of its space subnetted, tell me and I’ll add a “include gaps/free pool” option too.
