#!/bin/bash

ROLE_NAME="AuditReadOnlyRole"
OUTPUT_FILE="vpcs.csv"

# En-tête CSV
echo "AccountId,Region,VpcId,Cidr,Default" > $OUTPUT_FILE

# Liste des comptes actifs
ACCOUNTS=$(aws organizations list-accounts \
  --query "Accounts[?Status=='ACTIVE'].Id" \
  --output text)

for ACCOUNT_ID in $ACCOUNTS; do
  echo "🔹 Compte: $ACCOUNT_ID"

  # Assume role
  CREDS=$(aws sts assume-role \
    --role-arn arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME \
    --role-session-name list-vpcs \
    --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
    --output text 2>/dev/null)

  if [ $? -ne 0 ]; then
    echo "❌ Impossible d'assumer le rôle dans $ACCOUNT_ID"
    continue
  fi

  read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$CREDS"

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN

  # Régions actives
  REGIONS=$(aws ec2 describe-regions \
    --query "Regions[].RegionName" \
    --output text)

  for REGION in $REGIONS; do
    # Récupération VPCs
    aws ec2 describe-vpcs \
      --region $REGION \
      --query "Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Default:IsDefault}" \
      --output text 2>/dev/null | \
    while read VPC_ID CIDR DEFAULT; do
      echo "$ACCOUNT_ID,$REGION,$VPC_ID,$CIDR,$DEFAULT" >> $OUTPUT_FILE
    done
  done

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

echo "✅ Export terminé : $OUTPUT_FILE"
