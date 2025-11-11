Prérequis

- jq : Un processeur JSON en ligne de commande. Il doit être installé sur l'exécuteur de la GitHub Action (l'image ubuntu-latest l'inclut par défaut).
- curl : Outil pour effectuer des requêtes HTTP (inclus par défaut).
- Azure CLI (az) : L'interface de ligne de commande d'Azure. Vous devrez vous connecter en amont dans votre workflow.

- Variables d'environnement/Secrets :
  - NETBOX_URL: L'URL de votre instance NetBox (ex: https://netbox.example.com).
  - NETBOX_TOKEN: Votre token d'API NetBox avec les permissions nécessaires (lecture sur les préfixes et tenants, écriture sur les tenants).
  - AZURE_SUBSCRIPTION_NAME: Le nom de la souscription Azure, passé en paramètre au script.

- Le Script Bash (check_and_update_tenant.sh)

Ce script est conçu pour être robuste et fournir des messages clairs, ce qui est utile pour le débogage dans les logs de GitHub Actions.

```bash
#!/bin/bash

#-------------------------------------------------------------------------------
# SCRIPT : check_and_update_tenant.sh
#-------------------------------------------------------------------------------
# DESCRIPTION:
# Ce script vérifie si une souscription Azure, dont le nom correspond à certains
# préfixes (gts-, group-, lzsc-), est associée à un tenant dans NetBox.
# Si un tenant existe (nom = ID de la souscription), il vérifie si l'un de ses
# préfixes IP est géré par Terraform (via un custom field 'automation').
# Si aucun préfixe n'est géré par Terraform, le tenant est renommé pour
# indiquer qu'une mise à jour est nécessaire.
#
# USAGE:
# ./check_and_update_tenant.sh "nom-de-la-souscription-azure"
#
# VARIABLES D'ENVIRONNEMENT REQUISES:
# - NETBOX_URL: URL de l'instance NetBox (ex: https://netbox.example.com)
# - NETBOX_TOKEN: Token d'API NetBox
#-------------------------------------------------------------------------------

# Quitte immédiatement si une commande échoue
set -e
# Gère les erreurs dans les pipelines
set -o pipefail
# Traite les variables non définies comme des erreurs
set -u

# --- VÉRIFICATION DES PARAMÈTRES ET VARIABLES ---

if [ -z "${1:-}" ]; then
  echo "ERREUR : Le nom de la souscription Azure est requis en premier argument." >&2
  exit 1
fi
AZURE_SUBSCRIPTION_NAME="$1"

if [ -z "${NETBOX_URL:-}" ] || [ -z "${NETBOX_TOKEN:-}" ]; then
  echo "ERREUR : Les variables d'environnement NETBOX_URL et NETBOX_TOKEN doivent être définies." >&2
  exit 1
fi

# Headers pour les requêtes NetBox
NETBOX_HEADERS=(-H "Authorization: Token ${NETBOX_TOKEN}" -H "Content-Type: application/json" -H "Accept: application/json")

# --- ÉTAPE 1: VÉRIFIER LE NOM DE LA SOUSCRIPTION ---

echo "INFO: Analyse de la souscription : '${AZURE_SUBSCRIPTION_NAME}'"

if [[ "$AZURE_SUBSCRIPTION_NAME" != "azure-"* && "$AZURE_SUBSCRIPTION_NAME" != "azure2-"* && "$AZURE_SUBSCRIPTION_NAME" != "azure3-"* ]]; then
  echo "INFO: Le nom de la souscription ne correspond pas aux préfixes requis (gts-, group-, lzsc-). Arrêt du processus."
  exit 0
fi

echo "INFO: Le nom de la souscription correspond. Continuation..."

# --- ÉTAPE 2: OBTENIR L'ID DE LA SOUSCRIPTION AZURE ---

echo "INFO: Recherche de l'ID pour la souscription '${AZURE_SUBSCRIPTION_NAME}'..."
SUBSCRIPTION_ID=$(az account show --name "$AZURE_SUBSCRIPTION_NAME" --query id --output tsv)

if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERREUR: Impossible de trouver l'ID pour la souscription Azure '${AZURE_SUBSCRIPTION_NAME}'. Vérifiez le nom ou vos permissions." >&2
  exit 1
fi
echo "INFO: ID de souscription trouvé : ${SUBSCRIPTION_ID}"

# --- ÉTAPE 3: CHERCHER LE TENANT DANS NETBOX ---

TENANT_NAME="$SUBSCRIPTION_ID"
echo "INFO: Recherche d'un tenant dans NetBox avec le nom : '${TENANT_NAME}'..."

# Note: On filtre par 'name__iexact' pour être insensible à la casse, bien que les UUID soient normalement en minuscules.
# On récupère l'ID, le nom et le slug du tenant.
TENANT_DATA=$(curl -s -X GET "${NETBOX_URL}/api/tenancy/tenants/?name=${TENANT_NAME}" "${NETBOX_HEADERS[@]}" | jq '.results[0]')

TENANT_ID=$(echo "$TENANT_DATA" | jq -r '.id')

if [ -z "$TENANT_ID" ] || [ "$TENANT_ID" == "null" ]; then
  echo "INFO: Aucun tenant trouvé avec le nom '${TENANT_NAME}'. Arrêt du processus."
  exit 0
fi
echo "INFO: Tenant trouvé (ID: ${TENANT_ID})."

# --- ÉTAPE 4: VÉRIFIER LES PRÉFIXES DU TENANT ---

echo "INFO: Recherche des préfixes pour le tenant ID ${TENANT_ID}..."

# On récupère tous les préfixes du tenant et on vérifie directement la valeur du custom field "automation"
# jq sélectionne les valeurs non nulles du champ, grep cherche la chaîne, et wc compte les lignes.
MATCH_COUNT=$(curl -s -X GET "${NETBOX_URL}/api/ipam/prefixes/?tenant_id=${TENANT_ID}&limit=0" "${NETBOX_HEADERS[@]}" | \
              jq -r '.results[].custom_fields.automation | select(. != null)' | \
              grep -F "Managed by Terraform" | \
              wc -l)

# --- ÉTAPE 5: DÉCISION BASÉE SUR LE RÉSULTAT ---

if [ "$MATCH_COUNT" -gt 0 ]; then
  # Au moins un préfixe géré par Terraform a été trouvé
  echo "SUCCÈS: Au moins un préfixe avec 'Managed by Terraform' a été trouvé pour le tenant '${TENANT_NAME}'."
  echo "INFO: Aucune action requise. Le workflow continue."
  exit 0
else
  # Aucun préfixe géré par Terraform n'a été trouvé
  echo "AVERTISSEMENT: Aucun préfixe géré par Terraform trouvé pour le tenant '${TENANT_NAME}'."
  echo "ACTION: Renommage du tenant et de son slug."

  TENANT_SLUG=$(echo "$TENANT_DATA" | jq -r '.slug')
  NEW_NAME="${TENANT_NAME}UPDATEBYTF"
  NEW_SLUG="${TENANT_SLUG}UPDATEBYTF"
  
  # Création du corps de la requête PATCH en JSON
  JSON_PAYLOAD=$(jq -n --arg name "$NEW_NAME" --arg slug "$NEW_SLUG" '{name: $name, slug: $slug}')

  echo "INFO: Nouveau nom: ${NEW_NAME}"
  echo "INFO: Nouveau slug: ${NEW_SLUG}"

  # Envoi de la requête de mise à jour
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    "${NETBOX_URL}/api/tenancy/tenants/${TENANT_ID}/" \
    "${NETBOX_HEADERS[@]}" \
    --data "$JSON_PAYLOAD")

  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "SUCCÈS: Le tenant a été renommé avec succès."
    exit 0
  else
    echo "ERREUR: La mise à jour du tenant a échoué. Statut HTTP : ${HTTP_STATUS}" >&2
    exit 1
  fi
fi
```


- Exemple d'intégration dans un Workflow GitHub Actions
  
  - Voici comment vous pourriez utiliser ce script dans un fichier .github/workflows/main.yml. Cet exemple suppose que le nom de la souscription est une entrée du workflow.

```yaml
name: Check NetBox Tenants

on:
  workflow_dispatch:
    inputs:
      azure_subscription_name:
        description: 'Nom de la souscription Azure à vérifier'
        required: true
        type: string

jobs:
  check-and-update:
    runs-on: ubuntu-latest
    
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: 'Azure Login'
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }} # Secret contenant les infos du Service Principal

      - name: 'Install dependencies'
        run: |
          # az est déjà installé avec azure/login, jq et curl sont sur ubuntu-latest
          echo "Dependencies are ready."

      - name: 'Run Tenant Check Script'
        env:
          NETBOX_URL: ${{ secrets.NETBOX_URL }}
          NETBOX_TOKEN: ${{ secrets.NETBOX_API_TOKEN }}
        run: |
          # Rendre le script exécutable
          chmod +x ./check_and_update_tenant.sh
          # Exécuter le script en passant le nom de la souscription
          ./check_and_update_tenant.sh "${{ github.event.inputs.azure_subscription_name }}"
```          

Configuration des secrets GitHub :

Dans votre dépôt GitHub, allez dans Settings > Secrets and variables > Actions et ajoutez les secrets suivants :

- AZURE_CREDENTIALS : Les identifiants de votre Service Principal Azure au format JSON.
- NETBOX_URL : L'URL complète de votre NetBox.
- NETBOX_API_TOKEN : Le token d'API NetBox.
- Ce workflow vous permettra de déclencher manuellement la vérification pour une souscription donnée.






