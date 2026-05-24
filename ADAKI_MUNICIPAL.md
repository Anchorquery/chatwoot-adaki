# Adaki Municipal Extensions

Capa propia sobre Chatwoot fork para gestión centralizada WhatsApp Cloud API multi-municipio.

## Resumen módulos

| Módulo | Carpeta | Propósito |
|---|---|---|
| Absences | `app/models/adaki/absence.rb` | Periodos de ausencia + cobertura asignada |
| AuditLogger | `app/services/adaki/audit_logger.rb` | Append-only, hash-chained SHA256 |
| TierMonitor | `app/services/adaki/tier_monitor_service.rb` | Lectura Meta `messaging_limit_tier`, lock preventivo |
| CampaignApproval | `app/services/adaki/campaign_approval_service.rb` | Doble validación campañas |
| MediaIntegrity | `app/services/adaki/media_integrity_service.rb` | Verificación blobs ActiveStorage |

## Integraciones (prepend_mod_with)

- `enterprise/app/services/auto_assignment/assignment_service.rb` filtra agentes ausentes en auto-asignación.
- `enterprise/app/services/whatsapp/oneoff_campaign_service.rb` bloquea envío si campaña requiere aprobación y no aprobada, o si canal está tier-locked.

## Migración

```bash
rails db:migrate
# crea: adaki_absences, adaki_campaign_approvals,
#       adaki_whatsapp_tier_snapshots, adaki_audit_log_entries
# columnas channel_whatsapp: messaging_tier, quality_rating,
#   daily_conversation_limit, tier_checked_at, tier_locked, tier_lock_reason
# columnas campaigns: requires_approval, approval_status
```

## Cron Sidekiq

- `Adaki::WhatsappTierMonitorJob` cada 15 min — lee tier y quality de Meta, snapshot, lock si necesario.
- `Adaki::MediaIntegritySweepJob` diario 03:00 UTC — verifica blobs últimas 24h.

## API endpoints

```
GET    /api/v1/accounts/:id/adaki/absences
POST   /api/v1/accounts/:id/adaki/absences
PATCH  /api/v1/accounts/:id/adaki/absences/:id
DELETE /api/v1/accounts/:id/adaki/absences/:id

GET    /api/v1/accounts/:id/adaki/whatsapp_channels
POST   /api/v1/accounts/:id/adaki/whatsapp_channels/:id/refresh_tier
POST   /api/v1/accounts/:id/adaki/whatsapp_channels/:id/unlock_tier
GET    /api/v1/accounts/:id/adaki/whatsapp_channels/tier_snapshots/:channel_id

GET    /api/v1/accounts/:id/adaki/audit_log_entries
GET    /api/v1/accounts/:id/adaki/audit_log_entries/verify

POST   /api/v1/accounts/:id/campaigns/:campaign_id/approvals
POST   /api/v1/accounts/:id/campaigns/:campaign_id/approvals/approve
POST   /api/v1/accounts/:id/campaigns/:campaign_id/approvals/reject
```

## Garantías

**Auditoría inmutable**
- `Adaki::AuditLogEntry#readonly?` = true tras persistir
- destroy lanza `ActiveRecord::ReadOnlyRecord`
- `verify_chain!` recomputa SHA256 entrada-por-entrada, detecta tampering
- `pg_advisory_xact_lock` por account evita race condition en chain

**Tier safety**
- Warning a 75% del límite diario, lock automático a 95%
- Lock también si `quality_rating == "RED"` reportado por Meta
- Campaign con canal tier-locked falla en `enforce_tier_safety!`

**Doble validación**
- Campaign con `requires_approval=true` no se envía sin aprobación
- Aprobador debe ser usuario distinto al solicitante (validación modelo)

**Cobertura ausencias**
- Auto-asignación salta agentes en absence active
- `Adaki::AbsenceResolver#effective_assignee` resuelve cobertura
- Toda alta/baja/cancelación de absence se loguea en audit chain

## Mapeo a fases del proyecto

| Fase | Cubre |
|---|---|
| Fase 1 MVP | AuditLogger (GDPR día 1), MediaIntegrity verificador, GDPR pseudonymization |
| Fase 2 Escalado | Absences/Coverage, TierMonitor + lock, UI dashboard |
| Fase 3 Campañas | Doble validación + audit campañas + UI aprobaciones, audience estimation completa |
| Fase 4 IA | Captain (Chatwoot enterprise) + límites mensuales por account + audit invocaciones |
| Fase 5 SaaS | DR plan + backup script + audit export legal |

## Avisos legales / operativos

**GDPR vs auditoría inmutable**
- `Adaki::AuditLogEntry` es append-only por diseño legal (admin pública). No se borra.
- Si ciudadano pide derecho al olvido, el auditable referenciado puede pseudonimizarse, pero la entrada audit permanece (con `auditable_id` apuntando a ghost record). Documentar en política GDPR del municipio.
- Borrar `Account` (municipio) requiere borrar primero entradas audit o se levanta `ActiveRecord::ReadOnlyRecord`. Para retiradas de servicio: exportar audit a archivo legal antes.

**Hash chain determinismo**
- `Adaki::AuditLogger.canonical_json` ordena keys recursivamente. Re-serialización tras jsonb round-trip produce mismos bytes → `verify_chain!` estable.

**Tier safety estimación**
- `safe_to_send?` refresca tier si `tier_checked_at` >1h. Si Meta API falla, retorna conservador (limit conocido o nil).
- Campaign con audience por labels: `estimate_recipient_count` cuenta contactos tagged. Otros tipos audience pendientes.

## UI dashboard Vue

Settings sidebar items: Ausencias, Tier WhatsApp, Aprobaciones, Audit log.

- `app/javascript/dashboard/routes/dashboard/settings/adaki/{absences,tier,audit,approvals}/Index.vue`
- `app/javascript/dashboard/store/modules/adaki/{absences,tier,audit,approvals}.js`
- `app/javascript/dashboard/api/adaki/{absences,whatsappChannels,auditLog,campaignApprovals}.js`
- i18n EN+ES en `app/javascript/dashboard/i18n/locale/{en,es}/adaki.json`
- Badge inline en CampaignCard: `AdakiApprovalBadge.vue` muestra estado approval en lista campañas
- Página Captain limits en `settings/adaki/captain/Index.vue` para configurar `adaki_captain_monthly_limit` y ver uso periodo actual

## Tests RSpec

| Capa | Spec |
|---|---|
| Servicios | audit_logger, absence_resolver, campaign_approval_service, captain_usage_tracker, tier_monitor_service, media_integrity_service |
| Controllers | absences, audit_log_entries, whatsapp_channels, gdpr, captain_settings |
| Factories | adaki_absences, adaki_campaign_approvals, adaki_audit_log_entries, adaki_whatsapp_tier_snapshots, adaki_captain_usages |

## Captain limits + audit

- Migración `20260523000000_create_adaki_captain_usage.rb` añade `adaki_captain_usages` y `accounts.adaki_captain_monthly_limit`
- `Adaki::CaptainUsageTracker.enforce_limit!` / `.record!` enganchados via `Captain::ChatHelperAdaki` prepend
- Endpoints: `GET/PATCH /api/v1/accounts/:id/adaki/captain_settings`
- Cada invocación Captain queda en audit chain (`captain.<feature>.invocation`)

## GDPR pseudonymization

- `POST /api/v1/accounts/:id/adaki/gdpr/pseudonymize_contact` con `contact_id, reason`
- Contact → `ghost-<8hex>`, email/phone/identifier null, snapshot NO en audit (sin PII)
- Audit entry `gdpr.contact.pseudonymized` referencia contact por id

## Deploy Coolify

Ver [docs/adaki/deploy-coolify.md](docs/adaki/deploy-coolify.md) — paso a paso completo.

- `docker-compose.coolify.yaml` — rails + sidekiq + postgres pgvector + redis + perfil backup
- `docker/entrypoints/rails.sh` — corre `db:chatwoot_prepare` (idempotente) en arranque rails
- Sidekiq con `SKIP_DB_PREPARE=true`, depends_on rails healthy
- `.github/workflows/build-coolify-image.yml` — build + push GHCR + webhook Coolify
- Cron Adaki: tier monitor 15min, media sweep 03:00 UTC, audit chain verify dom 04:00 UTC

## DR / Backups

Ver [docs/adaki/dr.md](docs/adaki/dr.md):
- `bin/adaki-backup.sh` — pg_dump diario + S3 upload + retention
- `rake adaki:audit:export[ACCOUNT_ID]` — export legal JSONL + SHA256
- `rake adaki:audit:verify_all` — verificación integridad cadena de todas las cuentas
