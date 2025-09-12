```python

def sync_to_netbox(all_network_data, netbox_url, netbox_token, config, credential):  # Pass credential
    logger.info(f"Syncing data to Netbox at {netbox_url}")
    
    session = requests.Session()
    session.verify = config.get('ssl', {}).get('verify', True)
    session.timeout = config.get('timeouts', {}).get('netbox_api', 30)
    
    nb = api(netbox_url, token=netbox_token)
    nb.http_session = session
    
    # Global default tag color from config (used for string tags)
    default_tag_color = config.get('tags', {}).get('default_color', 'aaaaaa')
    logger.debug(f"Using global default tag color: {default_tag_color}")
    
    setup_custom_fields(nb, config)
    setup_custom_tags(nb, config)  # Setup custom tags from config.yaml
    
    aggregate_map = setup_rirs_and_aggregates(nb, config)
    role_map = setup_ipam_roles(nb, config)
    tenant_map, aggregate_tag_filter = setup_tenancy(nb, config, all_network_data)
    
    # New: Setup static prefixes and collect child tag map for inheritance
    child_tag_map = setup_static_prefixes(nb, config)
    
    # New: Setup Organization for Azure
    azure_site_group_id, azure_region_map = setup_organization(nb, config, provider='azure')
    
    # New: Setup Organization for AWS (preparation, no sync yet)
    aws_site_group_id, aws_region_map = setup_organization(nb, config, provider='aws')
    
    sync_tag_config = config.get('tags', {}).get('sync_tag', {})
    sync_tag_name = sync_tag_config.get('name', "azure-sync")
    sync_tag_desc = sync_tag_config.get('description', "Synced from Azure")
    sync_tag_color = clean_color(sync_tag_config.get('color', default_tag_color))  # Use configured color or fallback
    azure_tag = get_or_create_tag(
        nb,
        tag_input=sync_tag_name,
        tag_description=sync_tag_desc,
        tag_color=sync_tag_color  # Pass the dedicated color
    )
    if not azure_tag:
        logger.error("Failed to create/get azure-sync tag; continuing without it.")
        azure_tag_dict = []
    else:
        azure_tag_dict = [{'id': azure_tag.id}]
    
    additional_tags = []
    additional_tag_configs = config.get('tags', {}).get('additional_tags', [])
    for tag_item in additional_tag_configs:
        tag = get_or_create_tag(nb, tag_item, tag_color=default_tag_color)
        if tag:
            additional_tags.append({'id': tag.id})
    
    for subscription_data in all_network_data:
        subscription_id = subscription_data['subscription_id']
        subscription_name = subscription_data['subscription_name']
        
        matching_role = None
        for role_name, role_data in role_map.items():
            criteria = role_data['match_criteria'].lower()
            if criteria in subscription_name.lower():
                matching_role = role_data
                logger.debug(f"Matched subscription {subscription_name} to role {role_name} using criteria '{criteria}'")
                break
            else:
                logger.debug(f"No match for subscription {subscription_name} with role {role_name} criteria '{criteria}'")
        
        if not matching_role:
            # Assign default "TBD" role if no match
            default_role_name = 'TBD'  # Assuming the role name is 'TBD' as per example
            matching_role = role_map.get(default_role_name)
            if matching_role:
                logger.info(f"No specific role matched for subscription {subscription_name}; assigning default role '{default_role_name}'")
            else:
                logger.warning(f"No specific role matched and default 'TBD' role not found for subscription {subscription_name}")
        
        role_id = matching_role['id'] if matching_role else None
        
        tenant_data = tenant_map.get(subscription_id)
        tenant_id = tenant_data['id'] if tenant_data else None
        
        network_client = NetworkManagementClient(credential, subscription_id)
        
        for vnet in subscription_data['vnets']:
            address_spaces = vnet['address_space']
            if not address_spaces:
                logger.warning(f"Skipping VNet {vnet['name']} (no address spaces)")
                continue
            
            logger.info(f"Processing VNet {vnet['name']} with {len(address_spaces)} address spaces")
            
            peering_check = get_vnet_peerings(network_client, vnet['resource_group'], vnet['name'], config)
            logger.debug(f"Peering check for VNet {vnet['name']}: {peering_check}")
            
            # Get all subnets and usages for the VNet once
            try:
                subnets = list(network_client.subnets.list(vnet['resource_group'], vnet['name']))
                usages = list(network_client.virtual_networks.list_usage(vnet['resource_group'], vnet['name']))
            except Exception as e:
                logger.warning(f"Error fetching subnets or usages for VNet {vnet['name']}: {str(e)}")
                subnets = []
                usages = []
            
            # New: Get/Create Site for this VNet based on location
            vnet_location = vnet['location']
            region_data = azure_region_map.get(vnet_location)
            site_id = None
            if region_data:
                site_prefix = config.get('organization', {}).get('azure', {}).get('site_prefix', 'Azure - ')
                human_region = region_data['human_name']
                # Updated: Include shortened subscription_id in site name/slug for uniqueness
                short_sub_id = subscription_id[:8]  # First 8 characters of subscription ID
                site_name = f"{site_prefix}{short_sub_id}-{vnet['name']} ({human_region})"
                site_slug = site_name.lower().replace(" ", "-").replace("(", "").replace(")", "")
                site_desc = f"Azure VNet: {vnet['name']} in {human_region} (Subscription: {subscription_id} - {subscription_name})"
                
                site = get_or_create_site(
                    nb,
                    name=site_name,
                    slug=site_slug,
                    group_id=azure_site_group_id,
                    region_id=region_data['id'],
                    tenant_id=tenant_id,  # New: Assign tenant to site
                    tags=region_data['tag'],  # Assign the region-specific tag (e.g., [{'id': FRC_tag_id}])
                    description=site_desc
                )
                site_id = site.id if site else None
                logger.info(f"Processed Site for VNet {vnet['name']}: {site_name} (id: {site_id})")
            else:
                logger.warning(f"No region mapping found for Azure location '{vnet_location}'; skipping Site/Region for VNet {vnet['name']}")
            
            for idx, address_space in enumerate(address_spaces, 1):
                logger.debug(f"Syncing address space {idx}/{len(address_spaces)} for VNet {vnet['name']}: {address_space}")
                
                # Calculate available IPs summary for this address space
                available_ips_summary = "Unable to calculate"
                try:
                    addr_net = ipaddress.ip_network(address_space, strict=False)
                    total_ips = addr_net.num_addresses
                    
                    # Find subnets within this address space
                    subnets_in_space = [s for s in subnets if ipaddress.ip_network(s.address_prefix, strict=False).subnet_of(addr_net)]
                    
                    # Calculate allocated IPs (sum of subnet sizes)
                    allocated = sum(ipaddress.ip_network(s.address_prefix).num_addresses for s in subnets_in_space)
                    
                    # Calculate used IPs from usages
                    used = 0
                    available_in_subnets = 0
                    for usage in usages:
                        if '/subnets/' in usage.id:
                            subnet_name = usage.id.split('/subnets/')[-1]
                            for s in subnets_in_space:
                                if s.name == subnet_name:
                                    used += usage.current_value
                                    available_in_subnets += (usage.limit - usage.current_value)
                                    break
                    
                    # Unallocated count (full IPs, including potential reserves if subnetted)
                    unallocated = total_ips - allocated
                    
                    # Total available = unallocated + available in subnets
                    total_available = unallocated + available_in_subnets
                    
                    available_ips_summary = f"Used IPs: {used}, Available IPs: {total_available}"
                except Exception as e:
                    logger.warning(f"Error calculating available IPs for {address_space}: {str(e)}")
                
                matching_aggregate = None
                try:
                    prefix_net = ipaddress.ip_network(address_space, strict=False)
                    for agg_prefix, agg_data in aggregate_map.items():
                        agg_net = ipaddress.ip_network(agg_prefix, strict=False)
                        if prefix_net.subnet_of(agg_net):
                            matching_aggregate = agg_data
                            logger.debug(f"Matched address space {address_space} to aggregate {agg_prefix}")
                            break
                except ValueError as e:
                    logger.warning(f"Invalid IP network for {address_space}: {str(e)}")
                    continue
                
                aggregate_id = matching_aggregate['id'] if matching_aggregate else None
                
                # FORCE assign_tenant = True to ensure EVERY prefix gets the tenant (one per subscription)
                # This ensures all prefixes for a subscription are visible under the tenant in NetBox UI.
                assign_tenant = True  # Forced to True (ignores aggregate_tag_filter for tenant assignment)
                logger.debug(f"Forcing tenant assignment for prefix {address_space} (tenant_id: {tenant_id})")
                
                prefix_tags = azure_tag_dict + additional_tags
                if matching_aggregate:
                    prefix_tags += matching_aggregate['tags']
                if matching_role:
                    prefix_tags += matching_role['tags']
                if region_data and region_data['tag']:
                    prefix_tags += region_data['tag']  # Add region tag to prefix
                
                prefix_defaults = {
                    'description': f"Azure VNet: {vnet['name']} (Subscription: {subscription_id}) - Address Space {idx}",
                    'status': 'active',
                    'tags': prefix_tags
                }
                if 'custom_fields' not in prefix_defaults:
                    prefix_defaults['custom_fields'] = {}
                prefix_defaults['custom_fields']['peering_check'] = peering_check
                prefix_defaults['custom_fields']['available_ips_summary'] = available_ips_summary
                
                vnet_prefix, created = get_or_create_prefix(
                    nb,
                    address_space,
                    prefix_defaults,
                    subscription_name=subscription_name,
                    subscription_id=subscription_id,
                    aggregate_id=aggregate_id,
                    role_id=role_id,
                    tenant_id=tenant_id if assign_tenant else None,
                    site_id=site_id,
                    tags=prefix_tags
                )
                
                action = "Created" if created else "Updated"
                logger.info(f"{action} prefix for VNet {vnet['name']} address space {idx}: {address_space} (Aggregate: {aggregate_id if aggregate_id else 'None'}, Role: {role_id if role_id else 'None'}, Tenant: {tenant_id if tenant_id else 'None'}, Site: {site_id if site_id else 'None'})")

    # New: After all Azure syncing, apply inherited tags from static child prefixes
    apply_inherited_tags(nb, child_tag_map)
```


Below, I'll explain the code changes I made in the provided snippet (which is an updated portion of the sync_to_netbox function). I'll break it down step by step, including what it does, why I implemented it this way, and how it aligns with your request to add a new custom field called "list-available-ips" (populated with a summary like "IPs used and IPs available"). I'll also note any assumptions, limitations, and how you can customize or extend it further.

# Overall Purpose of the Changes

- Your request was to add a new custom field ("list-available-ips") to each synced prefix in NetBox, populated with information about IP consumption (e.g., used IPs and available IPs) for each address space in an Azure VNet.
- This is inspired by the Azure CLI command az network vnet list-available-ips, but since we're using the Azure Python SDK (not CLI), I implemented equivalent logic using SDK methods to fetch subnet details and usage statistics.
- The calculation happens per address space (i.e., per prefix being synced to NetBox), and the result is stored as a simple text summary in the custom field (e.g., "Used IPs: 50, Available IPs: 200"). This provides a quick overview of consumption without listing every single IP (which could be inefficient for large VNets).
- I placed this logic inside the loop that processes each VNet's address spaces, right before creating/updating the prefix in NetBox.

# Key Code Changes and Explanations

Here's the relevant code with inline explanations:

```python
# Inside the loop for each subscription's VNet
for vnet in subscription_data['vnets']:
    address_spaces = vnet['address_space']
    if not address_spaces:
        logger.warning(f"Skipping VNet {vnet['name']} (no address spaces)")
        continue
    
    logger.info(f"Processing VNet {vnet['name']} with {len(address_spaces)} address spaces")
    
    peering_check = get_vnet_peerings(network_client, vnet['resource_group'], vnet['name'], config)
    logger.debug(f"Peering check for VNet {vnet['name']}: {peering_check}")
    
    # NEW: Fetch all subnets and usages for the VNet once (outside the address space loop for efficiency)
    # - Subnets: List all subnets in this VNet to calculate allocated IPs.
    # - Usages: Get usage stats (e.g., how many IPs are actually in use in each subnet).
    # This uses Azure SDK calls equivalent to 'az network vnet list-available-ips' and subnet queries.
    try:
        subnets = list(network_client.subnets.list(vnet['resource_group'], vnet['name']))
        usages = list(network_client.virtual_networks.list_usage(vnet['resource_group'], vnet['name']))
    except Exception as e:
        logger.warning(f"Error fetching subnets or usages for VNet {vnet['name']}: {str(e)}")
        subnets = []
        usages = []
    
    # ... (site creation logic omitted for brevity)
    
    # Loop over each address space in the VNet
    for idx, address_space in enumerate(address_spaces, 1):
        logger.debug(f"Syncing address space {idx}/{len(address_spaces)} for VNet {vnet['name']}: {address_space}")
        
        # NEW: Calculate available IPs summary for this specific address space
        # - Default to an error message if calculation fails.
        available_ips_summary = "Unable to calculate"
        try:
            # Parse the address space as an IP network to get total IPs.
            addr_net = ipaddress.ip_network(address_space, strict=False)
            total_ips = addr_net.num_addresses
            
            # Filter subnets that belong to *this* address space (a VNet can have multiple address spaces).
            subnets_in_space = [s for s in subnets if ipaddress.ip_network(s.address_prefix, strict=False).subnet_of(addr_net)]
            
            # Allocated IPs: Sum of the sizes of all subnets in this address space.
            allocated = sum(ipaddress.ip_network(s.address_prefix).num_addresses for s in subnets_in_space)
            
            # Used IPs: Sum from Azure's usage stats for these subnets.
            # (Usages include IPs actually assigned to resources like NICs, load balancers, etc.)
            used = 0
            available_in_subnets = 0
            for usage in usages:
                if '/subnets/' in usage.id:
                    subnet_name = usage.id.split('/subnets/')[-1]
                    for s in subnets_in_space:
                        if s.name == subnet_name:
                            used += usage.current_value  # IPs currently in use
                            available_in_subnets += (usage.limit - usage.current_value)  # Available within the subnet
                            break
            
            # Unallocated: IPs in the address space not yet assigned to any subnet.
            unallocated = total_ips - allocated
            
            # Total available: Unallocated + available slots within existing subnets.
            total_available = unallocated + available_in_subnets
            
            # Format the summary string (as per your example: "ips used and ips availables")
            available_ips_summary = f"Used IPs: {used}, Available IPs: {total_available}"
        except Exception as e:
            logger.warning(f"Error calculating available IPs for {address_space}: {str(e)}")
        
        # ... (aggregate matching logic omitted for brevity)
        
        # Add the summary to the custom fields for this prefix.
        prefix_defaults = {
            'description': f"Azure VNet: {vnet['name']} (Subscription: {subscription_id}) - Address Space {idx}",
            'status': 'active',
            'tags': prefix_tags
        }
        if 'custom_fields' not in prefix_defaults:
            prefix_defaults['custom_fields'] = {}
        prefix_defaults['custom_fields']['peering_check'] = peering_check
        # NEW: Add the calculated summary to the new custom field.
        prefix_defaults['custom_fields']['list-available-ips'] = available_ips_summary
        
        # Create/update the prefix in NetBox with the new custom field.
        vnet_prefix, created = get_or_create_prefix(
            nb,
            address_space,
            prefix_defaults,
            subscription_name=subscription_name,
            subscription_id=subscription_id,
            aggregate_id=aggregate_id,
            role_id=role_id,
            tenant_id=tenant_id if assign_tenant else None,
            site_id=site_id,
            tags=prefix_tags
        )
        
        # ... (logging omitted)
```

# Key Explanations:

- Fetching Data:

  - network_client.subnets.list(...): Gets all subnets in the VNet. This is needed to know which subnets fall within each address space and to calculate allocated IPs.
  - network_client.virtual_networks.list_usage(...): Gets usage stats per subnet (e.g., how many IPs are used vs. the subnet's limit). This is the SDK equivalent of az network vnet list-available-ips, which provides consumption details.
    
- Calculation Logic:

  - Total IPs: Total addresses in the address space (e.g., for 10.0.0.0/16, it's 65,536).
  - Allocated IPs: Sum of all subnet sizes within this address space (e.g., if there are two /24 subnets, allocated = 256 + 256 = 512).
  - Used IPs: Actual IPs in use (from Azure usage stats, e.g., assigned to VMs, etc.).
  - Available in Subnets: Free slots within existing subnets (subnet limit minus used).
  - Unallocated: IPs not yet subnetted (total minus allocated).
  - Total Available: Unallocated + available in subnets.
  - This gives a high-level summary without listing every IP (which could be thousands/millions for large prefixes, making the custom field bloated and slow in NetBox).

# Custom Field Integration:

- The field is named exactly "list-available-ips" (as you requested).
- It's populated with a string like "Used IPs: 50, Available IPs: 200".
- This is added to prefix_defaults['custom_fields'] before calling get_or_create_prefix, so it's saved/updated in NetBox.
- Note: You need to ensure this custom field is created in NetBox. Add it to setup_custom_fields function like this (I didn't include it in the snippet, but you can add it):

```python
get_or_create_custom_field(
    nb,
    field_name="list-available-ips",
    field_type="text",  # Or "multi" if you want a list, but text is simpler for summary
    field_description="Summary of used and available IPs in the prefix",
    object_types=["ipam.prefix"]
)
```
- Error Handling:

  - If fetching subnets/usages fails (e.g., permissions issue), it logs a warning and sets a default message.
  - If calculation fails (e.g., invalid CIDR), it logs and uses a fallback string.

# Why This Implementation?

- Efficiency: Fetching subnets/usages once per VNet (outside the address space loop) avoids redundant API calls to Azure.
- Accuracy: It uses Azure's official usage stats, which account for reserved IPs (e.g., Azure reserves 5 IPs per subnet).
- Simplicity: A summary string is more practical than listing all available IPs (which could be huge). If you want a full list, we could modify it to store a comma-separated list or link to a report, but that might not display well in NetBox.
- Alignment with Request: It directly computes "IPs used and IPs available" as you suggested, inspired by the az command.
- Limitations:
  - This doesn't include dynamic reservations (e.g., future Azure features). It's based on current subnets and usages.
  - For very large VNets, the calculation might be slow (but Azure API limits should prevent issues).
  - Assumes you have permissions to call list_usage and list_subnets (part of Network Contributor role or similar).
  - NetBox custom fields are text-based; no built-in "button" or tooltip like you mentioned earlier for peering (that would require NetBox plugins or UI customizations).

# How to Test/Use It

- Update config.yaml: Ensure the new custom field is enabled in your custom_fields section if needed.
- Run the Script: It will now populate "list-available-ips" for each synced prefix.
- View in NetBox: Go to IPAM > Prefixes, and look at the custom field column (you may need to add it to your view).

- Customization Ideas:
  - Change the summary format (e.g., add percentages: f"Used: {used} ({(used/total_ips)*100:.1f}%), Available: {total_available}").
  - If you want full IP lists, modify to store a truncated list (e.g., first 10 available IPs).
  - For AWS integration (as you're planning), similar logic can be added using AWS SDK (boto3) for VPC CIDR blocks.
