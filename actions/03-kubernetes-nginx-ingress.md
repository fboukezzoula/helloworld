# Kubernetes avec NGINX Ingress Controller

## Objectif
Ingress Kubernetes standard avec routage par path URI.

## Architecture
Internet → Load Balancer → NGINX Ingress → Services

## Avantages
- Cloud agnostique
- Très flexible

## Exemple Ingress
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
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
