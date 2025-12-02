

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                     DUPLICATE ROLE VERSION CHECKER                          │
│                           Quick Reference                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SETUP                                                                      │
│  ─────                                                                      │
│  export AZURE_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"              │
│  export AZURE_CLIENT_SECRET="your-secret"                                   │
│  export AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"              │
│  chmod +x check_duplicate_role_versions.sh                                  │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  USAGE                                                                      │
│  ─────                                                                      │
│  ./check_duplicate_role_versions.sh BU1                                     │
│  ./check_duplicate_role_versions.sh BU1 --report                            │
│  ./check_duplicate_role_versions.sh BU1 --output report.log                 │
│  ./check_duplicate_role_versions.sh BU1 --report --output report.log        │
│  ./check_duplicate_role_versions.sh --help                                  │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  VIEW OUTPUT FILE WITH COLORS                                               │
│  ────────────────────────────                                               │
│  less -R report.log                                                         │
│  cat report.log                                                             │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  EXIT CODES                                                                 │
│  ──────────                                                                 │
│  0 = Success, no duplicates                                                 │
│  1 = Duplicates found or error                                              │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  CONFIGURATION                                                              │
│  ─────────────                                                              │
│  Edit MG_ROOT_MAPPING and GROUP_PREFIX_MAPPING in the script                │
│  to add new Business Units                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```
