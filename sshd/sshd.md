```Dockerfile
FROM codercom/code-server:latest

USER root

# Installer dependances
RUN dnf install -y \
      openssh-server \
      python3 \
      python3-pip \
    && dnf clean all

# Installer px (proxy PAC/NTLM/AD)
RUN pip3 install px-proxy

# Préparer sshd
RUN mkdir /var/run/sshd && \
    sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config && \
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config

# Créer un user non-root
RUN useradd -m coder && \
    mkdir -p /home/coder/.ssh && \
    chmod 700 /home/coder/.ssh

# Ajouter ta clé publique (fichier copié depuis le build context)
COPY id_ed25519.pub /home/coder/.ssh/authorized_keys
RUN chmod 600 /home/coder/.ssh/authorized_keys && \
    chown -R coder:coder /home/coder/.ssh

# Exposer ports
EXPOSE 8080 2222 3128

# Entrypoint : px + sshd + code-server
# px utilisera PAC et credentials AD passés en variables d'environnement
CMD px \
      --pac "$PX_PAC" \
      --user "$PX_USER" \
      --password "$PX_PASSWORD" \
      --listen 0.0.0.0:3128 & \
    /usr/sbin/sshd -D -e & \
    code-server --bind-addr 0.0.0.0:8080
```

🔧 Variables d’environnement attendues

Dans ton Deployment, tu dois définir :

```
PX_USER = DOMAIN\user ou user@domain.com
PX_PASSWORD = mot de passe AD (stocké en Secret)
PX_PAC = chemin vers PAC file (/config/proxy.pac si monté en ConfigMap) ou URL HTTP
```

Et les classiques pour que tout passe par px :

```
env:
  - name: HTTP_PROXY
    value: http://127.0.0.1:3128
  - name: HTTPS_PROXY
    value: http://127.0.0.1:3128
  - name: NO_PROXY
    value: localhost,127.0.0.1,.svc,.cluster.local
```

Parfait 🙌 voici un manifeste Kubernetes complet basé sur le Dockerfile qu’on a construit (code-server + sshd + px).
Il inclut :

Secret pour tes credentials AD

ConfigMap pour ton PAC file

Deployment pour ton Pod

Service exposant code-server (8080) + ssh (2222)


🔐 Secret pour ton compte AD
```
apiVersion: v1
kind: Secret
metadata:
  name: px-creds
type: Opaque
stringData:
  PX_USER: "DOMAIN\\monlogin"
  PX_PASSWORD: "monMotDePasseUltraSecret"

```


📜 ConfigMap pour le PAC file

Si tu as le PAC localement (ex. proxy.pac) :
```
apiVersion: v1
kind: ConfigMap
metadata:
  name: px-pac
data:
  proxy.pac: |
    function FindProxyForURL(url, host) {
      // Exemple minimal — remplace par ton vrai PAC
      return "PROXY proxy.company.com:8080";
    }
```

👉 si ton PAC est une URL (http://proxy.company.com/proxy.pac), tu peux sauter cette étape et mettre directement l’URL dans PX_PAC.


🚀 Deployment

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: code-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: code-server
  template:
    metadata:
      labels:
        app: code-server
    spec:
      containers:
        - name: code-server
          image: mon-registry/code-server-ssh-px:latest
          ports:
            - containerPort: 8080
            - containerPort: 2222
            - containerPort: 3128
          env:
            - name: HTTP_PROXY
              value: http://127.0.0.1:3128
            - name: HTTPS_PROXY
              value: http://127.0.0.1:3128
            - name: NO_PROXY
              value: localhost,127.0.0.1,.svc,.cluster.local
            - name: PX_USER
              valueFrom:
                secretKeyRef:
                  name: px-creds
                  key: PX_USER
            - name: PX_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: px-creds
                  key: PX_PASSWORD
            - name: PX_PAC
              value: /config/proxy.pac   # si monté depuis ConfigMap
          volumeMounts:
            - name: pac-file
              mountPath: /config
              readOnly: true
      volumes:
        - name: pac-file
          configMap:
            name: px-pac
```

🌐 Service
```
apiVersion: v1
kind: Service
metadata:
  name: code-server
spec:
  selector:
    app: code-server
  ports:
    - name: http
      port: 8080
      targetPort: 8080
    - name: ssh
      port: 2222
      targetPort: 2222
```

Résultat

code-server dispo via Service sur port 8080

sshd dispo via port 2222 (tu peux kubectl port-forward ou exposer plus largement si tu veux Remote-SSH)

px tourne en local dans le Pod → tout le trafic sort par ton PAC avec authentification AD

az login --use-device-code marche, le code est collé dans ton navigateur local

🔌 1. Port-forward pour SSH et code-server

Lance un port-forward depuis ton poste vers ton Pod/Service :
```
kubectl port-forward svc/code-server 8080:8080 2222:2222
```


🗝️ 2. Fichier ~/.ssh/config

Ajoute ceci dans ~/.ssh/config sur ton poste (Linux/macOS, ou C:\Users\<user>\.ssh\config sur Windows) :

```
Host codeserver
  HostName localhost
  Port 2222
  User coder
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
```

🖥️ 3. Connexion en SSH (test terminal)

ssh codeserver


Si tout est bon → tu arrives directement dans le shell du conteneur.


4. Remote-SSH depuis VS Code (local)

Installe l’extension Remote - SSH sur ton poste.

Clique sur la petite flèche verte en bas à gauche → "Connect to Host..." → choisis codeserver.

VS Code se connecte dans le conteneur via SSH.

Tu pourras bosser dedans comme si c’était local.

☁️ 5. Auth Azure

Dans code-server (navigateur) ou dans Remote-SSH (ton VS Code local) → ouvre un terminal :
```
az login --use-device-code
```

Tu obtiens un code XXXX-XXXX.
👉 Colle-le dans ton navigateur local → l’auth passe via ton proxy (géré par px dans le Pod).
Ton Pod est maintenant authentifié à Azure 🎉.

✅ Avec ça :

tu as un code-server full web, qui sait sortir via proxy (px)

tu peux dépanner via Remote-SSH

tu peux faire az login et bosser avec Azure CLI/Terraform/etc.









✅ Vérifications à faire

Inspecter le PAC (si tu l’as monté dans le Pod via ConfigMap) :

cat /config/proxy.pac


Vérifie que les retours de fonction FindProxyForURL() donnent bien des chaînes valides, du type :

PROXY proxy.company.com:8080

DIRECT

⚠️ Pas de /// ou d’URL complètes dans la partie PROXY.

Tester manuellement avec px
Tu peux lancer px en mode debug :

px --pac /config/proxy.pac --user "$PX_USER" --password "$PX_PASSWORD" --listen 0.0.0.0:3128 --debug


Ça te montrera exactement ce que px lit du PAC et tente de parser.

Si le PAC est en URL (ex. http://intra/proxy.pac)
Vérifie qu’il est bien accessible depuis ton Pod (en passant éventuellement par un proxy de bootstrap).

🔧 Solutions possibles

Corriger ton PAC (le plus propre) :
remplacer les lignes qui renvoient un PROXY ///... par quelque chose de valide (PROXY proxy.company.com:8080).

Forcer un proxy statique (bypass PAC) :
Si tu sais déjà que ton proxy est proxy.company.com:8080, tu peux lancer px sans PAC :

px --proxy proxy.company.com:8080 --user "$PX_USER" --password "$PX_PASSWORD" --listen 0.0.0.0:3128


Debug temporaire : logguer ce que renvoie ton proxy.pac avec un petit script Node/Python, pour voir la sortie de FindProxyForURL().

👉 Question : est-ce que ton PAC file est complexe (avec plein de règles), ou est-ce qu’il redirige toujours vers le même proxy (PROXY proxy.company.com:8080) ?

Si simple → on peut remplacer --pac par --proxy.

Si complexe → il faudra corriger le PAC (ou wrapper FindProxyForURL).

Tu veux que je t’aide à inspecter et corriger ton PAC file pour que px l’accepte ?
