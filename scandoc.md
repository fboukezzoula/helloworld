flowchart TD
  classDef cfg fill:#f0f9ff,stroke:#0ea5e9,color:#0c4a6e
  classDef az fill:#fefce8,stroke:#eab308,color:#713f12
  classDef sh fill:#f8fafc,stroke:#334155,color:#0f172a
  classDef py fill:#f5f3ff,stroke:#7c3aed,color:#2e1065
  classDef file fill:#ecfeff,stroke:#06b6d4,color:#0e7490
  classDef nb fill:#ecfdf5,stroke:#10b981,color:#064e3b
  classDef warn fill:#fff7ed,stroke:#f97316,color:#7c2d12
  classDef decision stroke-dasharray: 5 5

  A[Operator / Cron]:::sh --> B[azure-vnet-scan.sh]:::sh

  subgraph CFG[Config (env)]
    E1[SKIP_MG]:::cfg
    E2[AZ_TIMEOUT]:::cfg
    E3[ENABLE_IPV6]:::cfg
    E4[INCLUDE_EMPTY_SPACE]:::cfg
    E5[EXPAND_USED_WITH_RESOURCES]:::cfg
    E6[SUBS_EXCLUDE_REGEX]:::cfg
    E7[SKIP_LB | SKIP_APPGW | SKIP_AZFW | SKIP_BASTION | SKIP_VNGW | SKIP_PLS]:::cfg
  end
  B --- CFG

  B --> C[Gather subscriptions<br/>-s / -m / -a]:::az
  C --> C2[Exclude by name<br/>(SUBS_EXCLUDE_REGEX, case-insensitive)]:::sh

  C2 --> D{SKIP_MG = 1?}:::decision
  D -- Yes --> E[Skip MG mapping]:::sh
  D -- No --> F[Build Subscription → MG mapping]:::az

  E --> G
  F --> G

  G[For each subscription]:::sh --> H[az account set]:::az
  H --> I[List VNets]:::az
  I --> J[For each VNet: list subnets]:::az

  J --> K[Base used = length(subnet.ipConfigurations)]:::sh
  K --> L{EXPAND_USED_WITH_RESOURCES = 1?}:::decision
  L -- Yes --> M[Add 1 per matching resource IP:<br/>LB/AppGW/AzFW/Bastion/VNGW/PLS]:::az
  L -- No --> N[Skip resource expansion]:::sh
  M --> O[Build list: sid|||cidr|||used]:::sh
  N --> O

  O --> P[For each address space]:::sh
  P --> Q{Subnets in this space?}:::decision

  Q -- Yes --> R[Sum per subnet:<br/>available = size − reserved − used<br/>(IPv4=5, IPv6=2)]:::py
  Q -- No --> S{INCLUDE_EMPTY_SPACE = 1?}:::decision
  S -- Yes --> T[Set used=0,<br/>available = net_size − reserved]:::py
  S -- No --> U[Set used=0, available=0]:::py

  R --> V[Append row to CSV]:::file
  T --> V
  U --> V

  V --> W{Run NetBox updater?}:::decision
  W -- Yes --> X[update_list_available_ips.py]:::sh
  X --> Y[Ensure CFs:<br/>list_available_ips, ips_used, ips_available]:::nb
  X --> Z[Ensure tag 'ip-availables-sync' and apply]:::nb
  X --> AA{--create-missing?}:::decision
  AA -- Yes --> AB[Create missing container prefixes (global),<br/>tag 'ip-availables-sync']:::nb
  AA -- No --> AC[No creation]:::nb
  AB --> AD[PATCH prefixes CFs + tags]:::nb
  AC --> AD
  W -- No --> AE[Done]:::sh
