#!/bin/bash
echo "Account,Region,VpcId,Cidr,Default"
ROLE_NAME="AuditReadOnlyRole"

# Liste tous les comptes de l'organisation
ACCOUNTS=$(aws organizations list-accounts \
  --query "Accounts[?Status=='ACTIVE'].Id" \
  --output text)

for ACCOUNT_ID in $ACCOUNTS; do
  echo "======================================="
  echo "Compte: $ACCOUNT_ID"

  # Assume role
  CREDS=$(aws sts assume-role \
    --role-arn arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME \
    --role-session-name list-vpcs \
    --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
    --output text 2>/dev/null)

  if [ $? -ne 0 ]; then
    echo "❌ Impossible d'assumer le rôle"
    continue
  fi

  read AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$CREDS"

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN

  # Liste régions
  REGIONS=$(aws ec2 describe-regions \
    --query "Regions[].RegionName" \
    --output text)

  for REGION in $REGIONS; do
    VPCS=$(aws ec2 describe-vpcs \
      --region $REGION \
      --query "Vpcs[].VpcId" \    # --query "Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Default:IsDefault}"

      --output text 2>/dev/null)

    if [ -n "$VPCS" ]; then
      echo " Région $REGION:"
      for VPC in $VPCS; do
        echo "   - $VPC"
      done
    fi
  done

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done




import boto3

ec2 = boto3.client('ec2')

regions = [r['RegionName'] for r in ec2.describe_regions()['Regions']]

for region in regions:
    print(f"\n===== Région: {region} =====")
    ec2_regional = boto3.client('ec2', region_name=region)
    vpcs = ec2_regional.describe_vpcs()['Vpcs']

    for vpc in vpcs:
        print({
            "VpcId": vpc['VpcId'],
            "CidrBlock": vpc['CidrBlock'],
            "IsDefault": vpc['IsDefault']
        })
