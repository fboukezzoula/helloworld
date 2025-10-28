%%{init: {'theme': 'base', 'logLevel': 'error', 'flowchart': { 'curve': 'linear', 'htmlLabels': true }}}%%
flowchart TD
  classDef cfg fill:#f0f9ff,stroke:#0ea5e9,color:#0c4a6e
  classDef az fill:#fefce8,stroke:#eab308,color:#713f12
  classDef sh fill:#f8fafc,stroke:#334155,color:#0f172a
  classDef py fill:#f5f3ff,stroke:#7c3aed,color:#2e1065
  classDef file fill:#ecfeff,stroke:#06b6d4,color:#0e7490
  classDef nb fill:#ecfdf5,stroke:#10b981,color:#064e3b

  A[Operator / Cron]:::sh --> B[azure-vnet-scan.sh]:::sh

  subgraph CFG[Config env]
    E1[SKIP_MG]:::cfg
    E2[AZ_TIMEOUT]:::cfg
    E3[ENABLE_IPV6]:::cfg
    E4[INCLUDE_EMPTY_SPACE]:::cfg
    E5[EXPAND_USED_WITH_RESOURCES]:::cfg
    E6[SUBS_EXCLUDE_REGEX]:::cfg
    E7[SKIP_LB, SKIP_APPGW, SKIP_AZFW, SKIP_BASTION, SKIP_VNGW, SKIP_PLS]:::cfg
  end
  B --- CFG

  B --> C[Gather subscriptions<br/>-s / -m / -a]:::az
  C --> C2[Exclude by name &lpar;SUBS_EXCLUDE_REGEX&rpar;]:::sh

  C2 --> D{SKIP_MG = 1?}
  D -- Yes --> E[Skip MG mapping]:::sh
  D -- No --> F[Build Sub → MG mapping]:::az

  E --> G
  F --> G

  G[For each subscription]:::sh --> H[az account set]:::az
  H --> I[List VNets]:::az
  I --> J[For each VNet: list subnets]:::az

  J --> K[Base used = length of subnet.ipConfigurations]:::sh
  K --> L{EXPAND_USED_WITH_RESOURCES = 1?}
  L -- Yes --> M[Add 1 per resource IP:<br/>LB / AppGW / AzFW / Bastion / VNGW / PLS]:::az
  L -- No --> N[Skip resource expansion]:::sh
  M --> O[Build list: sid &#124;&#124;&#124; cidr &#124;&#124;&#124; used]:::sh
  N --> O

  O --> P[For each address space]:::sh
  P --> Q{Subnets in this space?}

  Q -- Yes --> R[available = size − reserved − used<br/>— IPv4=5, IPv6=2]:::py
  Q -- No --> S{INCLUDE_EMPTY_SPACE = 1?}
  S -- Yes --> T[used=0, available = net_size − reserved]:::py
  S -- No --> U[used=0, available=0]:::py

  R --> V[Append row → CSV]:::file
  T --> V
  U --> V

  V --> W{Run NetBox updater?}
  W -- Yes --> X[update_list_available_ips.py]:::sh
  X --> Y[Ensure CFs:<br/>list_available_ips, ips_used, ips_available]:::nb
  X --> Z[Ensure tag 'ip-availables-sync' and apply]:::nb
  X --> AA{--create-missing?}
  AA -- Yes --> AB[Create container prefixes &plus; tag 'ip-availables-sync']:::nb
  AA -- No --> AC[No creation]:::nb
  AB --> AD[PATCH prefixes &lpar;CFs &plus; tags&rpar;]:::nb
  AC --> AD
  W -- No --> AE[Done]:::sh

%%{init: {'theme': 'base', 'logLevel': 'error'}}%%
flowchart LR
  classDef step fill:#f8fafc,stroke:#334155,color:#0f172a
  classDef az fill:#fefce8,stroke:#eab308,color:#713f12
  classDef off fill:#f1f5f9,stroke:#cbd5e1,color:#475569

  A[Start expansion]:::step --> B{EXPAND_USED_WITH_RESOURCES=1?}
  B -- No --> Z[Skip]:::off
  B -- Yes --> C[Collect subnet IDs for VNet]:::step
  C --> LB[LB private frontends]:::az
  C --> AGW[AppGW private frontends]:::az
  C --> FW[Azure Firewall]:::az
  C --> BAS[Bastion]:::az
  C --> VNGW[VNet Gateway]:::az
  C --> PLS[Private Link Service]:::az
  LB --> D[+1 used on matching subnet]:::step
  AGW --> D
  FW --> D
  BAS --> D
  VNGW --> D
  PLS --> D
  
