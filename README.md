# siyuan-deploy

Orchestration Docker pour le stack Siyuan (back-office) + extracteur + reader.

## Environnements

| Dossier | Description |
|---|---|
| [dev/](dev/) | Environnement de développement local (bind mounts, hot-reload, watch). Voir [dev/README.md](dev/README.md). |

*Prod / staging à venir.*

## Composants déployés (dev)

- **siyuan** — `b3log/siyuan:latest`, port host 6806.
- **extractor** — Node 20 + tsx, port host 3001. Repo : [Zipkhn/siyuan-extractor](https://github.com/Zipkhn/siyuan-extractor).
- **reader** — Node 20 + Next.js, port host 3002. Repo : [Zipkhn/siyuan-reader](https://github.com/Zipkhn/siyuan-reader).

## Repos liés

| Repo | Rôle |
|---|---|
| [Zipkhn/siyuan](https://github.com/Zipkhn/siyuan) | Fork de `siyuan-note/siyuan` (back-office, branche `custom/main`). |
| [Zipkhn/siyuan-plugin-publish](https://github.com/Zipkhn/siyuan-plugin-publish) | Plugin Siyuan qui marque les docs publiés et appelle le webhook extracteur. |
| [Zipkhn/siyuan-extractor](https://github.com/Zipkhn/siyuan-extractor) | Reçoit les webhooks, lit Siyuan via API bornée, écrit snapshots JSON + HTML. |
| [Zipkhn/siyuan-reader](https://github.com/Zipkhn/siyuan-reader) | Next.js + Auth.js, sert les snapshots à des lecteurs invités. |

## État non-versionné (gitignored)

Pour chaque env :
- `<env>/.env` — secrets locaux
- `<env>/workspace/` — workspace Siyuan bind-mounté
- `<env>/backups/` — backups produits par `scripts/backup.sh`
