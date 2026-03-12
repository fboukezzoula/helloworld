```

#!/usr/bin/env bash

set -e

SIZE="Standard_ND96isr_H200_v5"
IMAGE="Ubuntu2204"

TMP_RG="rg-h200-capacity-test"
TEST_VM="h200-capacity-test"

TFVARS_FILE="terraform.auto.tfvars"

echo ""
echo "Searching Azure regions with H200 capacity..."
echo ""

############################################
# Latence approximative vers FranceCentral
############################################

declare -A LATENCY

LATENCY[germanywestcentral]=10
LATENCY[italynorth]=15
LATENCY[northeurope]=20
LATENCY[uksouth]=25
LATENCY[swedencentral]=30
LATENCY[norwayeast]=35
LATENCY[eastus]=90
LATENCY[southafricanorth]=160

############################################
# Récupérer régions supportant H200
############################################

REGIONS=$(az vm list-skus \
--all \
--resource-type virtualMachines \
--query "[?name=='$SIZE'].locations[]" \
-o tsv | sort -u)

echo "Regions with H200 support:"
echo "$REGIONS"
echo ""

############################################
# Création RG temporaire si besoin
############################################

if ! az group show --name $TMP_RG &>/dev/null; then
    az group create --name $TMP_RG --location eastus >/dev/null
fi

############################################
# Trier par latence
############################################

SORTED_REGIONS=$(for r in $REGIONS; do
    echo "${LATENCY[$r]:-999} $r"
done | sort -n | awk '{print $2}')

############################################
# Test capacité réelle
############################################

for REGION in $SORTED_REGIONS
do

    echo "-----------------------------------"
    echo "Testing region: $REGION"

    #####################################
    # Vérifier restrictions abonnement
    #####################################

    RESTRICTION=$(az vm list-skus \
        --location $REGION \
        --size $SIZE \
        --query "[0].restrictions" \
        -o tsv)

    if [[ "$RESTRICTION" != "" ]]; then
        echo "Blocked by subscription restrictions"
        continue
    fi

    #####################################
    # Test allocation réelle
    #####################################

    echo "Testing allocation..."

    OUTPUT=$(az vm create \
        --resource-group $TMP_RG \
        --location $REGION \
        --name $TEST_VM \
        --size $SIZE \
        --image $IMAGE \
        --admin-username azureuser \
        --generate-ssh-keys \
        --validate 2>&1 || true)

    if echo "$OUTPUT" | grep -q "OverconstrainedAllocationRequest"; then
        echo "No capacity available"
        continue
    fi

    if echo "$OUTPUT" | grep -q "Allocation failed"; then
        echo "Allocation failed"
        continue
    fi

    #####################################
    # Région valide
    #####################################

    echo ""
    echo "SUCCESS: H200 capacity available in $REGION"
    echo ""

    #####################################
    # Générer terraform.auto.tfvars
    #####################################

    cat > $TFVARS_FILE <<EOF
location_gpu = "$REGION"
EOF

    echo "Generated $TFVARS_FILE"

    #####################################
    # Lancer Terraform
    #####################################

    terraform init
    terraform apply -auto-approve

    exit 0

done

echo ""
echo "No Azure region currently has H200 capacity."
exit 1
```

