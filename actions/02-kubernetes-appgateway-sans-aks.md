# Kubernetes sans AKS + Application Gateway

## Objectif
Utiliser Azure Application Gateway avec un cluster Kubernetes self-managed.

## Architecture
Internet → App Gateway → AGIC → Kubernetes

## Attention
AGIC sans AKS n’est pas officiellement supporté.

## Installation
AGIC via Helm avec Service Principal Azure.
