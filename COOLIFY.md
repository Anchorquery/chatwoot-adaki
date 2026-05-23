# Deploy Chatwoot Adaki en Coolify

Stack: rails + sidekiq + postgres (pgvector) + redis. Imagen build vía GH Actions → GHCR → Coolify pulls.

## Arquitectura

```
                    ┌─────────────────────────────────────┐
[Dev local]         │ Coolify (VPS)                       │
docker compose up   │  ┌─────────┐  ┌──────────┐         │
   (dev stack)      │  │ rails   │  │ sidekiq  │         │
        ↓           │  │ :3000   │  │          │         │
  edit code         │  └────┬────┘  └────┬─────┘         │
        ↓           │       │            │               │
  git push main     │       └────┬───────┘               │
        ↓           │       ┌────▼────┐  ┌─────────┐    │
[GH Actions]        │       │ postgres│  │  redis  │    │
  build image       │       │ pgvector│  │         │    │
        ↓           │       └─────────┘  └─────────┘    │
[GHCR]              │                                     │
ghcr.io/.../...     │  Traefik proxy → chat.adaki.com    │
        ↓           └─────────────────────────────────────┘
[Coolify webhook]
  pull + restart
```

## Setup inicial (una vez)

### 1. GitHub secrets

Repo Settings → Secrets and variables → Actions:

- `COOLIFY_WEBHOOK_URL` (opcional) — Coolify app → Webhooks → Deploy URL
- `COOLIFY_TOKEN` (opcional) — Coolify → Keys & Tokens → API token

Sin esto el workflow build/pushea pero deploy manual.

### 2. Habilitar GH Actions permisos packages

Repo Settings → Actions → General → Workflow permissions → **Read and write permissions** ✅

### 3. Hacer GHCR package público (opcional, simplifica pull en Coolify)

Tras primer push: GitHub → Packages → `chatwoot-adaki` → Settings → Change visibility → Public.

Si privado: configurar pull secret en Coolify.

### 4. Servidor Coolify

VPS Ubuntu 22.04+, mín. 4 GB RAM (8 GB recomendado), 40 GB disco:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
```

Apuntar DNS `chat.adaki.com` → IP VPS.

### 5. Crear app en Coolify

1. Coolify Dashboard → **New Resource** → **Docker Compose Empty**
2. Source: **Git Repository** → conectar `chatwoot-adaki` (GitHub App)
3. Branch: `main`
4. Compose file path: `docker-compose.coolify.yaml`
5. Domain: `https://chat.adaki.com` → port `3000` → Service `rails`
6. SSL: Let's Encrypt ✅

### 6. Environment variables

Coolify → app → **Environment Variables** → pegar `.env.coolify.example` y rellenar.

**Generar secrets:**

```bash
# SECRET_KEY_BASE
openssl rand -hex 64

# POSTGRES_PASSWORD / REDIS_PASSWORD
openssl rand -base64 32

# Active Record Encryption keys (local, una sola vez)
docker compose run --rm rails bundle exec rails db:encryption:init
# copia las 3 keys del output
```

### 7. Pre-deploy command (db setup)

Coolify → app → **Pre-deploy command**:

```
bundle exec rails db:chatwoot_prepare
```

Solo necesario primer deploy + cuando hay migraciones.

### 8. Trigger primer build

```bash
git push origin main
```

GH Actions → workflow `Build & Push Coolify Image` → ~25 min primer build, cached <10 min después.

### 9. Deploy en Coolify

UI Coolify → app → **Deploy**. Coolify pulls imagen GHCR, crea volúmenes, levanta servicios.

## Flujo dev diario

### Local (full stack desarrollo)

```bash
docker compose up
# http://localhost:3000
```

Edita código → hot reload Rails + vite. Modelos/migraciones:

```bash
docker compose run --rm rails bundle exec rails g model Foo bar:string
docker compose run --rm rails bundle exec rails db:migrate
```

### Deploy

```bash
git add .
git commit -m "feat: nueva funcionalidad"
git push origin main
```

→ GH Actions build & push → (auto)deploy Coolify.

## Comandos útiles Coolify

Coolify UI → app → **Terminal**:

```bash
# Console Rails
docker exec -it <rails-container> bundle exec rails c

# Logs Sidekiq
docker logs -f <sidekiq-container>

# Migración manual
docker exec <rails-container> bundle exec rails db:migrate

# Crear superadmin
docker exec -it <rails-container> bundle exec rails c
> User.create!(name:'Admin', email:'admin@adaki.com', password:'STRONG', confirmed_at: Time.now, type:'SuperAdmin')
```

## Backups

Coolify → app → **Backups** → habilitar backups Postgres a S3/local.

Mínimo: backup `postgres_data` + `storage_data` volumes.

## Troubleshooting

| Problema | Fix |
|----------|-----|
| Imagen GHCR no descarga (403) | Package privado → añade secret Coolify o hacer público |
| `SECRET_KEY_BASE` vacío | Setear en env vars Coolify, redeploy |
| 502 tras deploy | Rails health check tarda 90s; espera. Si persiste: revisa logs `rails` |
| Migraciones no corren | Pre-deploy command vacío. Setear `bundle exec rails db:chatwoot_prepare` |
| Postgres no inicia | `POSTGRES_PASSWORD` vacío. Generar y setear |
| Assets 404 | Build no precompiló. Revisar log GH Actions `assets:precompile` |
| Out of memory build | VPS <4GB. Build en GH Actions (ya configurado), no en VPS |

## Variables que NUNCA debes commitear

`.env`, `.env.coolify`, cualquier archivo con `SECRET_KEY_BASE`, passwords, API keys.

Ya cubierto por `.gitignore`. Verifica antes de cada push:

```bash
git status --ignored | grep -E "\.env"
```
