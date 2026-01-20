👉 Application Gateway avec load balancing basé sur le path URI (ex: /api, /app, /images).

Je prends Azure Application Gateway (Layer 7) comme référence, car c’est exactement son usage.

🎯 Objectif

Rediriger le trafic selon l’URI :

URL	Backend
/api/*	Backend API
/app/*	Backend Web
/images/*	Backend Images
🧱 Architecture
Client
  |
IP publique
  |
Azure Application Gateway
  |
Routing par path URI
  ├── /api     → Pool API (VMs / App Service)
  ├── /app     → Pool Web
  └── /images  → Pool Images

🛠️ Étapes de création (Azure Portal)
1️⃣ Créer les backends (Backend Pools)

Chaque pool correspond à un path.

Exemple :

backend-api

VM1 : 10.0.1.4

VM2 : 10.0.1.5

backend-web

VM3 : 10.0.2.4

backend-images

App Service ou VM

2️⃣ Créer l’Application Gateway
Paramètres clés :

SKU : Standard_v2 ou WAF_v2

Réseau : subnet dédié

IP publique : obligatoire

Protocol : HTTP / HTTPS

3️⃣ Configurer le Listener

Le listener écoute les requêtes entrantes.

Exemple :

Protocol : HTTP

Port : 80

Listener name : listener-http

(HTTPS possible avec certificat SSL)

4️⃣ Créer les HTTP Settings

Ils définissent comment l’App Gateway parle aux backends.

Exemple http-setting-api :

Port : 80

Protocol : HTTP

Path override : ❌

Cookie-based affinity : ❌

Health probe : recommandé

Créer 1 HTTP setting par backend si nécessaire.

5️⃣ Créer une règle de routage basée sur le path
Type de règle :

👉 Path-based routing

Exemple de Path Map
Path	Backend Pool	HTTP Setting
/api/*	backend-api	http-setting-api
/app/*	backend-web	http-setting-web
/images/*	backend-images	http-setting-images
/* (default)	backend-web	http-setting-web

📌 Le /* est obligatoire comme fallback.

6️⃣ Créer la règle

Listener : listener-http

Path Map : celle définie ci-dessus

Priority : 100 (exemple)

7️⃣ Health Probes (important)

Créer une probe par backend :

Backend	Path probe
API	/api/health
Web	/health
Images	/images/health

➡️ Sans probe OK = backend retiré du load balancing

🔍 Exemple de flux réel

Requête :

http://myapp.com/api/users


➡️ Application Gateway :

Match /api/*

Envoie vers backend-api

Load balance (round-robin)

🧪 Vérification
curl http://myapp.com/api
curl http://myapp.com/app
curl http://myapp.com/images

⚠️ Bonnes pratiques

✔ Toujours prévoir /*
✔ Ne pas mélanger TCP (SSH, DB) → L7 HTTP uniquement
✔ Utiliser HTTPS + WAF si public
✔ Probes spécifiques par path

🧩 Exemple équivalent en Terraform (simplifié)
path_rule {
  name                       = "api-path"
  paths                      = ["/api/*"]
  backend_address_pool_name  = "backend-api"
  backend_http_settings_name = "http-setting-api"
}

Tu veux la suite ?👉 Application Gateway avec load balancing basé sur le path URI (ex: /api, /app, /images).

Je prends Azure Application Gateway (Layer 7) comme référence, car c’est exactement son usage.

🎯 Objectif

Rediriger le trafic selon l’URI :

URL	Backend
/api/*	Backend API
/app/*	Backend Web
/images/*	Backend Images
🧱 Architecture
Client
  |
IP publique
  |
Azure Application Gateway
  |
Routing par path URI
  ├── /api     → Pool API (VMs / App Service)
  ├── /app     → Pool Web
  └── /images  → Pool Images

🛠️ Étapes de création (Azure Portal)
1️⃣ Créer les backends (Backend Pools)

Chaque pool correspond à un path.

Exemple :

backend-api

VM1 : 10.0.1.4

VM2 : 10.0.1.5

backend-web

VM3 : 10.0.2.4

backend-images

App Service ou VM

2️⃣ Créer l’Application Gateway
Paramètres clés :

SKU : Standard_v2 ou WAF_v2

Réseau : subnet dédié

IP publique : obligatoire

Protocol : HTTP / HTTPS

3️⃣ Configurer le Listener

Le listener écoute les requêtes entrantes.

Exemple :

Protocol : HTTP

Port : 80

Listener name : listener-http

(HTTPS possible avec certificat SSL)

4️⃣ Créer les HTTP Settings

Ils définissent comment l’App Gateway parle aux backends.

Exemple http-setting-api :

Port : 80

Protocol : HTTP

Path override : ❌

Cookie-based affinity : ❌

Health probe : recommandé

Créer 1 HTTP setting par backend si nécessaire.

5️⃣ Créer une règle de routage basée sur le path
Type de règle :

👉 Path-based routing

Exemple de Path Map
Path	Backend Pool	HTTP Setting
/api/*	backend-api	http-setting-api
/app/*	backend-web	http-setting-web
/images/*	backend-images	http-setting-images
/* (default)	backend-web	http-setting-web

📌 Le /* est obligatoire comme fallback.

6️⃣ Créer la règle

Listener : listener-http

Path Map : celle définie ci-dessus

Priority : 100 (exemple)

7️⃣ Health Probes (important)

Créer une probe par backend :

Backend	Path probe
API	/api/health
Web	/health
Images	/images/health

➡️ Sans probe OK = backend retiré du load balancing

🔍 Exemple de flux réel

Requête :

http://myapp.com/api/users


➡️ Application Gateway :

Match /api/*

Envoie vers backend-api

Load balance (round-robin)

🧪 Vérification
curl http://myapp.com/api
curl http://myapp.com/app
curl http://myapp.com/images

⚠️ Bonnes pratiques

✔ Toujours prévoir /*
✔ Ne pas mélanger TCP (SSH, DB) → L7 HTTP uniquement
✔ Utiliser HTTPS + WAF si public
✔ Probes spécifiques par path

🧩 Exemple équivalent en Terraform (simplifié)
path_rule {
  name                       = "api-path"
  paths                      = ["/api/*"]
  backend_address_pool_name  = "backend-api"
  backend_http_settings_name = "http-setting-api"
}

Tu veux la suite ?
