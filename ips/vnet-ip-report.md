Best solution: Pure Linux-native script using az cli + jq (no PowerShell needed)

This script does exactly what your PowerShell script does — but better and more accurately because it uses Microsoft’s official az network vnet subnet list-available-ips command, which returns only the truly assignable IPs (automatically excludes the 5 Azure-reserved addresses .0–.4 + broadcast + any used IPs).


<img width="801" height="336" alt="image" src="https://github.com/user-attachments/assets/c02b6346-4c3d-4e41-8aba-235bd97cc71e" />
