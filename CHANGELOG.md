Step 1 — Disable AKS KEDA Add-on
```
az aks disable-addons \
  --addons keda \
  --name <cluster-name> \
  --resource-group <resource-group>
```

Verify removal:
```
kubectl get pods -A | grep keda
```

Step 2 — Create Dedicated Namespace
```
kubectl create namespace keda-dedicated
```

Step 3 — Install KEDA via Helm

Add Helm repository:
```
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```
Install into your namespace:
```
helm install keda kedacore/keda \
  --namespace keda-dedicated \
  --create-namespace
Step 4 — Verify Installation
kubectl get pods -n keda-dedicated
kubectl get crds | grep keda
```

🎯 Best Practice Recommendation

For AKS environments:

✔ Use the AKS-managed KEDA
✔ Deploy workloads in separate namespaces
✔ Use namespace-level isolation
✔ Use RBAC for access control
✔ Use Azure Workload Identity if needed

❌ Do not install a second KEDA instance unless absolutely necessary

💬 Architecture Clarification

Before installing a second KEDA instance, consider your actual objective:

Isolation per team?

Different KEDA versions?

Custom configuration not allowed in AKS add-on?

Testing environment?

Most use cases can be solved without running multiple KEDA operators.

Summary

If AKS KEDA add-on is enabled, use it.
Only deploy a separate KEDA instance after disabling the managed add-on to avoid CRD and operator conflicts.
