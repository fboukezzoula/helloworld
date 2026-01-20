👉 Architecture AKS + Application Gateway Ingress Controller (AGIC)

🎯 Objectif

Exposer plusieurs services Kubernetes avec un seul point d’entrée, en fonction du path URI :

URL	Service Kubernetes
/api	service-api
/app	service-web
/admin	service-admin
🧱 Architecture globale
Internet
   |
IP Publique
   |
Azure Application Gateway (L7)
   |
AGIC (Ingress Controller)
   |
AKS
 ├─ service-api
 ├─ service-web
 └─ service-admin


👉 AGIC traduit automatiquement les Ingress Kubernetes en règles App Gateway

1️⃣ Prérequis

✔ AKS (Azure Kubernetes Service)
✔ Application Gateway Standard_v2 ou WAF_v2
✔ Subnet dédié pour App Gateway
✔ Droits RBAC (Contributor minimum)

2️⃣ Créer l’Application Gateway

Paramètres importants :

SKU : Standard_v2 ou WAF_v2

Frontend : IP publique

Listener : HTTP ou HTTPS

Subnet : dédié uniquement à App Gateway

⚠️ Ne PAS configurer de règles manuellement → AGIC s’en charge.

3️⃣ Installer AGIC (Application Gateway Ingress Controller)
Option recommandée : Add-on AKS
az aks enable-addons \
  --addons ingress-appgw \
  --name myAKS \
  --resource-group myRG \
  --appgw-id /subscriptions/.../applicationGateways/myAppGw


👉 Azure :

installe AGIC dans AKS

donne les permissions à App Gateway

synchronise automatiquement

4️⃣ Déployer les services Kubernetes
Exemple API
apiVersion: v1
kind: Service
metadata:
  name: service-api
spec:
  selector:
    app: api
  ports:
  - port: 80
    targetPort: 8080


Même principe pour service-web, service-admin.

5️⃣ Créer l’Ingress avec Path-based Routing
Ingress Kubernetes
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: service-api
            port:
              number: 80

      - path: /app
        pathType: Prefix
        backend:
          service:
            name: service-web
            port:
              number: 80

      - path: /admin
        pathType: Prefix
        backend:
          service:
            name: service-admin
            port:
              number: 80

6️⃣ Ce que fait AGIC automatiquement

✔ Crée les backend pools
✔ Crée les HTTP settings
✔ Configure les listeners
✔ Met en place les path rules
✔ Gère le load balancing

📌 Aucune configuration manuelle dans App Gateway

7️⃣ Health Probes (important)

AGIC génère des probes automatiques, mais tu peux les personnaliser :

metadata:
  annotations:
    appgw.ingress.kubernetes.io/health-probe-path: "/health"

8️⃣ HTTPS (optionnel mais recommandé)
Certificat TLS
spec:
  tls:
  - hosts:
    - myapp.mondomaine.com
    secretName: tls-secret


AGIC :

configure HTTPS

associe le certificat

termine le SSL au niveau App Gateway

9️⃣ WAF (sécurité)

Si App Gateway est en WAF_v2 :

protection OWASP activée

règles personnalisables

compatible avec Ingress sans config supplémentaire

🔍 Vérification
kubectl get ingress
kubectl describe ingress app-ingress


Tester :

curl http://<IP_APPGW>/api
curl http://<IP_APPGW>/app

⚠️ Bonnes pratiques

✔ 1 App Gateway = plusieurs Ingress OK
✔ Toujours utiliser pathType: Prefix
✔ Probes explicites pour les API
✔ HTTPS + WAF pour Internet
✔ Ne pas modifier App Gateway à la ma
