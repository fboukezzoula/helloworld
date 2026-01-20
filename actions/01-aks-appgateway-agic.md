# Kubernetes avec AKS + Azure Application Gateway (AGIC)

## 🎯 Objectif
Exposer plusieurs services Kubernetes via un Application Gateway Azure
avec routage basé sur le path URI.

## Architecture
Internet → App Gateway → AGIC → AKS → Services

## Avantages
- Intégration Azure native
- Support officiel
- WAF L7

## Inconvénients
- Dépendant d’Azure

## Exemple Ingress
```yaml
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
```
