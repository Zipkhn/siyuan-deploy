# Dev environment — Siyuan + plugin publish + extractor + reader (Docker Compose)

Lance les 3 services en Docker :
- **siyuan** : Siyuan kernel + UI (port 6806).
- **extractor** : reçoit les webhooks du plugin et écrit les snapshots (port 3001).
- **reader** : Next.js qui sert les snapshots aux lecteurs invités (port 3002).

Bind mounts pour hot-reload des 3 composants.

## Pré-requis

- Docker Desktop lancé.
- Plugin construit : `cd ../../siyuan-plugin-publish && npm install && npm run build`. Le dossier `dist/` doit exister et contenir `index.js`, `plugin.json`, `i18n/`.
- Extracteur : son `node_modules` est installé automatiquement au premier `docker compose up` (volume nommé persistant).

## Démarrer

```bash
cp .env.example .env
# édite .env (au minimum SIYUAN_ACCESS_AUTH_CODE)

docker compose up -d
docker compose logs -f siyuan       # boot Siyuan
docker compose logs -f extractor    # boot extracteur (npm install + tsx watch)
```

Puis :
1. Ouvre http://localhost:6806 dans ton navigateur.
2. Saisis le code d'accès défini dans `.env`.
3. Settings → Marketplace → onglet **Installed** → active **Publish**.
4. Settings → About → **API token** : copie-le, colle-le dans `.env` (`SIYUAN_TOKEN=`), puis `docker compose restart extractor` pour qu'il pick le token.
5. Settings du plugin Publish : configure le webhook
   - URL : **`http://localhost:3001/webhook`** — le plugin tourne **dans le navigateur**, donc il atteint l'extracteur via le host port forward (3001), pas via le DNS Docker.
   - Secret : la même valeur que `EXTRACTOR_WEBHOOK_SECRET` dans `.env`.
   - L'extracteur autorise les origins `localhost`/`127.0.0.1` via CORS pour le dev.

## Hot reload du plugin

Dans un autre terminal, garde le watcher Vite en route :

```bash
cd ../../siyuan-plugin-publish
npm run dev   # vite build --watch
```

Chaque sauvegarde côté `src/` rebuilde `dist/`. Côté Siyuan, **Cmd-R** (reload navigateur) suffit pour recharger le plugin.

Si tu changes `plugin.json` ou `i18n/` : il faut **désactiver puis réactiver** le plugin dans Settings → Marketplace → Installed, ou redémarrer le conteneur (`docker compose restart siyuan`).

## Arrêter

```bash
docker compose down
```

## Reset complet du workspace de test

```bash
docker compose down
rm -rf workspace
```

## Layout

```
deploy/dev/
├── docker-compose.yml   # siyuan + extractor
├── .env.example
├── .env                 # gitignored
├── .gitignore
├── README.md
└── workspace/           # workspace Siyuan (gitignored)
    └── data/
        └── plugins/
            └── siyuan-plugin-publish/   # ← bind mount vers ../../siyuan-plugin-publish/dist
```

Volumes Docker nommés :
- `extractor-node-modules` — cache `node_modules` de l'extracteur (sinon le bind mount écraserait celui du conteneur).
- `snapshots` — racine `/data/snapshots` écrite par l'extracteur, consommée plus tard par le reader.

## Backup & restore

Procédure simple pour sauvegarder l'ensemble du stack et restaurer en cas de pépin. Pas de chiffrement / pas de push cloud en V1 — les archives sont écrites localement dans `deploy/dev/backups/<timestamp>/`.

### Ce qui est sauvegardé

| Source | Type | Contenu |
|---|---|---|
| `workspace/` | bind mount hôte | Workspace Siyuan complet : data/, plugins/, storage/, conf/, history/, assets/. |
| volume `snapshots` | volume Docker | Sortie de l'extracteur : JSON canoniques + HTML sanitisés + assets content-addressed. |
| volume `reader-db` | volume Docker | SQLite du reader (users, projects, documents, ACL, sessions, FTS index). |

### Lancer un backup

```bash
cd deploy/dev
./scripts/backup.sh
```

Le script :
1. Stoppe les 3 services (sans toucher aux volumes).
2. Tar.gz du `workspace/` depuis l'hôte.
3. Tar.gz de chaque volume Docker via un conteneur alpine éphémère.
4. Redémarre les services.
5. Écrit `MANIFEST.txt` listant les fichiers + tailles.

Durée typique : quelques secondes pour un workspace modeste. Pendant le backup, Siyuan et le reader sont indisponibles (~10-30s).

Tu peux changer le dossier de destination via `BACKUP_ROOT=/chemin/ailleurs ./scripts/backup.sh` (utile pour pointer vers un disque externe / NAS).

### Lister les backups

```bash
ls -la backups/
cat backups/<timestamp>/MANIFEST.txt
```

### Restaurer

```bash
./scripts/restore.sh <timestamp>
# ex : ./scripts/restore.sh 20260517T143000Z
```

⚠️ **Destructif** : le restore remplace `workspace/` ET recrée les volumes Docker `snapshots` + `reader-db` à partir des archives. Le script demande confirmation (`yes`) avant d'agir.

Workflow restore :
1. `docker compose down` (containers supprimés, volumes conservés temporairement).
2. Suppression des volumes existants.
3. Recréation des volumes + extraction du contenu archivé.
4. `docker compose up -d`.

Après restore : vérifier `docker compose logs --tail 30` pour confirmer que les 3 services repartent correctement.

### Automatisation (cron)

Pour un backup quotidien à 3h du matin :
```cron
0 3 * * * cd /Users/fares/Desktop/Siyuan/deploy/dev && BACKUP_ROOT=/Volumes/Backup/siyuan ./scripts/backup.sh >> /tmp/siyuan-backup.log 2>&1
```

Combine avec une rotation pour éviter l'accumulation infinie :
```cron
30 3 * * * find /Volumes/Backup/siyuan -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +
```
(garde 30 jours)

### Limites V1

- Pas de chiffrement at-rest. Si tu pousses les backups sur un cloud, chiffre avec `age` ou `gpg` avant.
- Pas de checksum d'intégrité (sha256). À ajouter dans une V1.1.
- Pas de backup incrémental — chaque backup = full. Tolérable tant que la volumétrie est faible.
- Pas de vérification post-restore automatique. À tester manuellement.

## Notes

- Les ports sont bindés sur `127.0.0.1` (Siyuan : 6806, extracteur : 3001) — pas exposés sur ton réseau local.
- L'access auth code Siyuan est requis car les requêtes viennent du réseau bridge Docker (non-localhost du point de vue de Siyuan).
- Le mount du plugin n'est **pas** en `:ro` : l'entrypoint Siyuan fait un `chown -R` sur tout le workspace au boot (avec `set -e`), et un mount read-only le ferait échouer en boucle. Sur macOS Docker Desktop, le chown ne modifie pas réellement l'ownership côté hôte. Les rebuilds restent pilotés par Vite côté hôte ; Siyuan ne réécrit pas les fichiers d'un plugin de lui-même.
- L'extracteur est joignable :
  - Depuis le navigateur (plugin) : `http://localhost:3001/webhook` ← c'est ce qu'il faut configurer dans les Settings du plugin.
  - Depuis l'hôte (curl, debug) : `http://localhost:3001/health`.
  - Depuis un autre conteneur du compose : `http://extractor:3000/...` (DNS Docker interne, inutile pour le plugin).
