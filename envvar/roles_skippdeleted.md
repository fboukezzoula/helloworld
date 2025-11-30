    ```bash
    while IFS= read -r subscription_id; do
        [[ -z "${subscription_id}" ]] && continue
        
        ((++processed))
        
        # Récupérer le nom de la souscription
        local sub_name
        sub_name=$(az account show --subscription "${subscription_id}" --query "name" -o tsv 2>/dev/null || echo "${subscription_id}")
        
        # === NOUVEAU : Ignorer les souscriptions contenant "DELETED" ===
        if [[ "${sub_name^^}" == *"DELETED"* ]]; then
            log_warning "Skipping deleted subscription: ${sub_name}" >&2
            continue
        fi
        # ================================================================
        
        printf "\r  Analyse: [%3d/%3d] %-50s" "${processed}" "${sub_count}" "${sub_name:0:50}"
        
        # ... reste du code
```    

```bash
# Après les autres déclarations de compteurs
local skipped_subscriptions=0

# Dans la boucle, au lieu de juste "continue"
if [[ "${sub_name^^}" == *"DELETED"* ]]; then
    log_warning "Skipping deleted subscription: ${sub_name}" >&2
    ((++skipped_subscriptions))
    continue
fi

# Dans le résumé final
echo "  Souscriptions analysées            : ${sub_count}"
echo "  Souscriptions ignorées (DELETED)   : ${skipped_subscriptions}"
echo "  Souscriptions avec groupe assigné  : ${subscriptions_with_group}"
```
