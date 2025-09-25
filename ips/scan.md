Très bien, on ajoute un filtre d’exclusion par nom de souscription pour ignorer celles qui contiennent “DELETED”.

Ce que ça fait

Par défaut, toute souscription dont le nom contient “DELETED” (insensible à la casse) est exclue du scan.
Tu peux changer/désactiver le filtre via une variable d’environnement:
SUBS_EXCLUDE_REGEX="DELETED|DISABLED" pour plusieurs motifs
SUBS_EXCLUDE_REGEX="" pour désactiver l’exclusion
Patch à appliquer dans azure-vnet-scan.sh (safe-copy)

Déclare la variable (près des autres variables globales)

```
# Exclure les subscriptions dont le nom matche ce regex (insensible à la casse)
# Par défaut: "DELETED". Mettre SUBS_EXCLUDE_REGEX="" pour désactiver.
SUBS_EXCLUDE_REGEX="${SUBS_EXCLUDE_REGEX:-DELETED}"
```

Ajoute la doc dans l’aide (optionnel, dans print_help)


  Env:
    SUBS_EXCLUDE_REGEX=DELETED     Exclure les subscriptions dont le nom matche ce motif (case-insensitive)
Filtre la liste des subscriptions après la déduplication, avant le check “== 0” et avant le log “Subscriptions à scanner”

Remplace le bloc juste après l’unicité par ceci:

```
# Unicité
IFS=$'\n' SUBS_LIST=($(printf "%s\n" "${SUBS_LIST[@]}" | awk '!seen[$0]++'))
unset IFS

# Filtre d'exclusion par nom (insensible à la casse)
if [[ -n "${SUBS_EXCLUDE_REGEX:-}" ]]; then
  pattern="$SUBS_EXCLUDE_REGEX"
  before=${#SUBS_LIST[@]}
  filtered=()
  for item in "${SUBS_LIST[@]}"; do
    sname="${item#*::}"
    if echo "$sname" | grep -qiE "$pattern"; then
      log INFO "Skip subscription (name matches exclude): $sname"
      continue
    fi
    filtered+=("$item")
  done
  SUBS_LIST=("${filtered[@]}")
  after=${#SUBS_LIST[@]}
  log INFO "Excluded $((before - after)) subscription(s) by name pattern: ${pattern}"
fi

if [[ ${#SUBS_LIST[@]} -eq 0 ]]; then
  echo "Erreur: aucune subscription trouvée après filtrage." >&2
  exit 3
fi

log INFO "Subscriptions à scanner: ${#SUBS_LIST[@]}"
```

Exemples

Comportement par défaut (exclut “DELETED”):
./azure-vnet-scan.sh -a -o out.csv -v

Désactiver le filtre:
SUBS_EXCLUDE_REGEX="" ./azure-vnet-scan.sh -a -o out.csv

Exclure plusieurs motifs:
SUBS_EXCLUDE_REGEX="DELETED|DISABLED|LEGACY" ./azure-vnet-scan.sh -a -o out.csv

Notes

Le filtrage s’applique quel que soit le mode (-s, -m, -a).
Le matching est insensible à la casse (DELETED, Deleted, deleted…).
Si tu préfères un flag CLI (ex: --exclude-name "regex") au lieu de la variable d’env, je peux te fournir le patch getopts correspondant.
