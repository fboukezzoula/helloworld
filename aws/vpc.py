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
