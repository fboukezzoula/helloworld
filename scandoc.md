flowchart LR
  classDef step fill:#f8fafc,stroke:#334155,color:#0f172a
  classDef az fill:#fefce8,stroke:#eab308,color:#713f12
  classDef off fill:#f1f5f9,stroke:#cbd5e1,color:#475569,stroke-dasharray: 4 4

  A[Start expansion]:::step --> B{EXPAND_USED_WITH_RESOURCES=1?}
  B -- No --> Z[Skip]:::off
  B -- Yes --> C[Collect subnet IDs of this VNet]:::step
  C --> LB[LB private frontends]:::az
  C --> AGW[AppGW private frontends]:::az
  C --> FW[Azure Firewall (resource)]:::az
  C --> BAS[Bastion (resource)]:::az
  C --> VNGW[VNet Gateway (resource)]:::az
  C --> PLS[Private Link Service]:::az
  LB --> D[+1 used on matching subnet]:::step
  AGW --> D
  FW --> D
  BAS --> D
  VNGW --> D
  PLS --> D
