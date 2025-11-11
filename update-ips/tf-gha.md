```bash

```





# Scenario 1: Tenant is correctly managed

```text
🔍 Step 1: Analyzing subscription: 'adam-496875-g3c-hml'
👍 INFO: Subscription name matches. Proceeding...
⚙️ Step 2: Fetching Azure Subscription ID...
✅ SUCCESS: Found Subscription ID: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9
🔍 Step 3: Searching for NetBox tenant named '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'...
✅ SUCCESS: Tenant found (ID: 678).
🔍 Step 4: Inspecting prefixes for tenant ID 678...
ℹ️ INFO: Tenant has 5 prefix(es) in total.
ℹ️ INFO: Found 5 prefix(es) with 'Managed by Terraform'.
▶️ Step 5: Making a decision...
🎉 SUCCESS: At least one prefix is managed by Terraform for tenant '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'.
➡️ INFO: No action required. Workflow continues.
```


# Scenario 2: Tenant needs to be updated (your original case)

```text
🔍 Step 1: Analyzing subscription: 'adam-496875-g3c-hml'
👍 INFO: Subscription name matches. Proceeding...
⚙️ Step 2: Fetching Azure Subscription ID...
✅ SUCCESS: Found Subscription ID: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9
🔍 Step 3: Searching for NetBox tenant named '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'...
✅ SUCCESS: Tenant found (ID: 678).
🔍 Step 4: Inspecting prefixes for tenant ID 678...
ℹ️ INFO: Tenant has 1 prefix(es) in total.
ℹ️ INFO: Found 0 prefix(es) with 'Managed by Terraform'.
▶️ Step 5: Making a decision...
⚠️ WARNING: No Terraform-managed prefixes found for tenant '03ed1681-c0ea-49e8-be69-d6a65e5a88a9'.
🔄 ACTION: Renaming tenant and its slug...
ℹ️ INFO: New name will be: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9UPDATEBYTF
ℹ️ INFO: New slug will be: 03ed1681-c0ea-49e8-be69-d6a65e5a88a9UPDATEBYTF
🎉 SUCCESS: Tenant has been renamed successfully.
```
          
