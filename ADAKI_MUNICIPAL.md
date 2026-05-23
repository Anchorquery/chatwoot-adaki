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
| Fase 1 MVP | AuditLogger (GDPR día 1), MediaIntegrity verificador |
| Fase 2 Escalado | Absences/Coverage, TierMonitor + lock |
| Fase 3 Campañas | Doble validación + audit campañas |
| Fase 4 IA | Captain (Chatwoot enterprise ya desbloqueado) |

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

## Pendiente Vue/UI

Backend listo. UI dashboard Vue por construir:
- `app/javascript/dashboard/routes/dashboard/settings/adaki/` — vistas absences/tier/audit
- `app/javascript/dashboard/store/modules/adaki/` — stores Vuex
