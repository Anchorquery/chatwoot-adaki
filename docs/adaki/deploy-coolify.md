# Deploy Adaki Chatwoot en Coolify

## 0. Pre-requisitos

- Servidor Coolify configurado (>= v4)
- Dominio DNS apuntando al servidor (A record o CNAME)
- Cuenta GitHub con push access al repo
- GHCR habilitado en GitHub org

## 1. Build inicial de imagen

```bash
git push origin main
```

GitHub Action `build-coolify-image.yml` arranca, construye imagen multi-stage Ruby+Node y publica en `ghcr.io/<owner>/<repo>:latest`.

Verificar: GitHub → Packages → debe aparecer `chatwoot-adaki` con tag `latest` + `sha-<commit>`.

Si GHCR es privado, autorizar Coolify:
- Coolify → Sources → Add Docker Registry
- URL: `ghcr.io`, Username: GitHub user, Password: PAT con `read:packages`

## 2. Generar secrets

En máquina local:

```bash
# SECRET_KEY_BASE
openssl rand -hex 64

# Active Record encryption keys (3 valores)
docker run --rm -it ruby:3.4-alpine sh -c "
  gem install bundler --silent
  cat <<'EOF' > /tmp/g.rb
require 'securerandom'
3.times { puts SecureRandom.alphanumeric(32) }
EOF
  ruby /tmp/g.rb
"

# POSTGRES_PASSWORD + REDIS_PASSWORD
openssl rand -base64 32
openssl rand -base64 32

# VAPID keys (push notifications)
# https://d3v.one/vapid-key-generator/
```

Guardar todos en gestor de secretos del cliente.

## 3. Crear resource en Coolify

1. Coolify → Projects → New Resource → **Docker Compose**
2. Source: connect to repo `chatwoot-adaki` branch `main`
3. Compose file: `docker-compose.coolify.yaml`
4. Auto-deploy on push: **enabled**

## 4. Environment variables

Pegar contenido de `.env.coolify.example` en Coolify UI → Environment Variables. Reemplazar todos los `REPLACE_*`:

| Variable | Valor |
|---|---|
| `GHCR_IMAGE` | `ghcr.io/<owner>/chatwoot-adaki:latest` |
| `SECRET_KEY_BASE` | salida `openssl rand -hex 64` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | 1ª línea generada |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | 2ª línea |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | 3ª línea |
| `FRONTEND_URL` | `https://chat.tudominio.com` |
| `POSTGRES_PASSWORD` | password fuerte |
| `REDIS_PASSWORD` | password fuerte |
| `SMTP_*` | datos SMTP (Resend/SES/etc.) |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` | generadas |

## 5. Mapear dominio

Coolify → Resource → Domains → Add:
- Service: `rails`
- Domain: `chat.tudominio.com`
- HTTPS: **Let's Encrypt enabled**

## 6. Primer deploy

Botón **Deploy**. Tail logs:

- `postgres` levanta primero
- `redis` levanta segundo
- `rails` arranca → entrypoint corre `pg_isready` loop → `db:chatwoot_prepare` (schema-load + seed primera vez)
- Healthcheck a `/api` debe pasar en 90-180s
- `sidekiq` arranca tras `rails healthy`

## 7. Crear primer super admin

```bash
docker exec -it <rails-container> bundle exec rails c
```

```ruby
SuperAdmin.create!(email: 'admin@tudominio.com', password: 'TempPass2026!', password_confirmation: 'TempPass2026!')
```

Login en `https://chat.tudominio.com/super_admin`.

## 8. Crear primer account/municipio

Login → Super Admin → Accounts → New:
- Name: nombre municipio
- Locale: `es`

User admin → Settings → Inboxes → New → WhatsApp Cloud:
- Phone Number ID + Business Account ID + Access Token (Meta)
- Webhook callback: `https://chat.tudominio.com/webhooks/whatsapp/<phone>`
- Configurar webhook en Meta panel apuntando a esa URL + verify_token

## 9. Habilitar Adaki settings

Sidebar settings → entradas Adaki visibles para admin:
- **Ausencias**: alta usuarios + fechas + cobertura
- **Tier WhatsApp**: `Refrescar` el canal recién creado para poblar `messaging_tier`
- **Aprobaciones**: solo si campañas marcan `requires_approval=true`
- **Audit log**: verificar cadena
- **Captain limits**: opcional, set `adaki_captain_monthly_limit`

## 10. Smoke checks

```bash
# Cadena audit OK
docker exec <rails-container> bundle exec rake adaki:audit:verify_all

# Sidekiq cron jobs cargados
docker exec <rails-container> bundle exec rails runner 'puts Sidekiq::Cron::Job.all.map(&:name)'
# Debe incluir adaki_whatsapp_tier_monitor_job, adaki_media_integrity_sweep_job, adaki_audit_chain_verify_job

# WhatsApp test message: enviar a número de canal y verificar inbox
```

## 11. Backups

### Opción A — Coolify Scheduled Task (recomendado)

Coolify → Scheduled Tasks → New:
- Container: `sidekiq`
- Frequency: `0 3 * * *` (daily 3am UTC)
- Command: `bin/adaki-backup.sh`

### Opción B — Profile `backup`

Editar resource → activar profile `backup` en compose → redeploy.

### S3 offsite

Añadir env vars en Coolify:
```
BACKUP_S3_BUCKET=adaki-backups
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=eu-west-1
```

## 12. Updates / rolling deploys

Push a `main` → GHA build → Coolify webhook (si configurado) → pull image → restart.

`db:chatwoot_prepare` corre cada arranque, migraciones nuevas se aplican antes que Rails sirva tráfico.

## 13. Rollback

Coolify → Deployments → seleccionar deploy anterior → **Redeploy**.

Migraciones forward-only por defecto. Si rollback requiere bajar schema:

```bash
docker exec <rails-container> bundle exec rails db:rollback STEP=N
```

⚠️ Auditar contra `db/schema.rb` antes de rollback en producción con datos reales.

## 14. Monitorización

- Logs en Coolify UI (rails + sidekiq + postgres)
- Sentry: setear `SENTRY_DSN` en env
- Sidekiq UI: `https://chat.tudominio.com/sidekiq` (requiere super_admin auth)
- Adaki audit log viewer: `/app/accounts/<id>/settings/adaki/audit`

## 15. Troubleshooting

### Migración falla en arranque
- Logs rails: `docker logs <rails-container>`
- Conectar manual: `docker exec <rails-container> bundle exec rails db:migrate:status`

### WhatsApp webhook no llega
- Verificar `FB_VERIFY_TOKEN` coincide con configurado en Meta
- Verificar `FRONTEND_URL` HTTPS válido (Meta rechaza HTTP)
- Logs sidekiq queue `medium` para `Webhooks::WhatsappEventsJob`

### Tier monitor no actualiza
- Verificar `provider_config.api_key` + `phone_number_id` válidos en `Channel::Whatsapp`
- Manual: `docker exec <c> bundle exec rails runner 'Adaki::TierMonitorService.new(Channel::Whatsapp.first).perform'`

### Audit chain rota
```bash
docker exec <c> bundle exec rake adaki:audit:verify_all
# Si falla, exportar última cadena íntegra:
docker exec <c> bundle exec rake adaki:audit:export[<account_id>]
```
Ver `docs/adaki/dr.md` plan de retirada.
