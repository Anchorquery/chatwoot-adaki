# Captain — Cómo funcionan los límites

Tres capas independientes pueden bloquear (o no) una respuesta del bot. Todas
conviven y todas tienen que estar abiertas para que el bot responda.

## Capa 1 — Cuota de plan de Chatwoot (`CAPTAIN_CLOUD_PLAN_LIMITS`)

**Fuente:** `InstallationConfig` con `name = 'CAPTAIN_CLOUD_PLAN_LIMITS'`
(Super Admin → System → Captain Cloud Plan Limits).

**Lógica:** [enterprise/app/models/enterprise/account/plan_usage_and_limits.rb:87](enterprise/app/models/enterprise/account/plan_usage_and_limits.rb:87)
→ `default_captain_limits`

| Caso | Resultado |
|---|---|
| Config vacío (default de fábrica) | `max_limit` → ilimitado |
| Config con JSON + `account.custom_attributes['plan_name']` blank | `zero_limits` → **bot bloqueado** |
| Config con JSON + `plan_name` matchea | usa los límites del plan |
| Config con JSON + `plan_name` no matchea | `zero_limits` → **bot bloqueado** |
| JSON parse falla | `max_limit` → ilimitado (fail-open) |

**Para deshabilitar:** dejar el campo `value` vacío en Super Admin
(o no setear nunca `plan_name` en la account si el JSON está cargado).

**Sobre-escritura por cuenta:** se puede setear `account.limits['captain_responses']`
(numérico) — gana sobre el default. Útil para topear un cliente puntual.

**Consumo:** `account.custom_attributes['captain_responses_usage']` cuenta cada
respuesta del bot. Reset manual: `account.reset_response_usage`.

## Capa 2 — Cuota Adaki mensual (`adaki_captain_monthly_limit`)

**Fuente:** columna `accounts.adaki_captain_monthly_limit` (integer, nullable).

**Lógica:** [app/services/adaki/captain_usage_tracker.rb:4-14](app/services/adaki/captain_usage_tracker.rb:4)
→ `enforce_limit!`

| Valor en la cuenta | Resultado |
|---|---|
| `nil` (default) | sin tope — pasa libre |
| `0` | sin tope — pasa libre |
| `N > 0` | cuenta `Adaki::CaptainUsage.request_count` mensual; si alcanza N → `LimitExceeded` |

**Endpoint admin:** `GET/PATCH /api/v1/accounts/:id/adaki/captain_settings`
(controller [captain_settings_controller.rb](app/controllers/api/v1/accounts/adaki/captain_settings_controller.rb)).

**UI:** Settings → Adaki → Captain ([settings/adaki/captain/Index.vue](app/javascript/dashboard/routes/dashboard/settings/adaki/captain/Index.vue)).
Dejar el campo vacío = sin tope.

**Reset mensual:** automático. La tabla `adaki_captain_usages` indexa por
`(account_id, period = beginning_of_month)`; cada mes nuevo arranca en 0.

**Auditoría:** cada llamada deja registro en `Adaki::AuditLogEntry` con
`action = "captain.<feature>.invocation"` y tokens consumidos.

## Capa 3 — Inbox activo (`Inbox#captain_active?`)

**Lógica:** [enterprise/app/models/enterprise/inbox.rb:15-23](enterprise/app/models/enterprise/inbox.rb:15)

```ruby
def captain_active?
  captain_assistant.present? && captain_assistant.autopilot_enabled? && more_responses?
end

def more_responses?
  account.usage_limits[:captain][:responses][:current_available].positive?
end
```

Requiere las TRES condiciones simultáneamente:

1. **Asistente vinculado al inbox** (tabla `captain_inboxes` — Settings → Inbox → Captain).
2. **Autopilot ON** en el asistente (`config['autopilot_enabled'] = true`).
3. **Cuota disponible > 0** según Capa 1 + override por cuenta.

Si falla cualquiera de las tres → `HookExecutionService#trigger_templates`
ejecuta `perform_handoff` (mensaje de transferencia, no silencio).

## Diagrama de decisión por mensaje entrante

```
incoming msg
  │
  ▼
HookExecutionService#perform
  │
  ├─ group? && !bot_mentioned?  → return (silencio)
  │
  ▼
trigger_templates
  │
  ├─ !should_process_captain_response?  → return (silencio)
  │     (captain_autopilot_enabled? + controllable + incoming)
  │
  ├─ !inbox.captain_active?  → perform_handoff (transfer msg)
  │
  ▼
schedule_captain_response (Sidekiq)
  │
  ▼
Captain::Conversation::ResponseBuilderJob#perform
  │
  ├─ !conversation_captain_controllable?  → return (silencio)
  │
  ▼
AssistantChatService.generate_response
  │
  ├─ Adaki::CaptainUsageTracker.enforce_limit!  → LimitExceeded
  │
  ├─ Platform::CredentialManager.with_credential_context
  │     │  (raise MissingCredential si falta key)
  │     ▼
  │   RubyLLM chat.ask → response JSON
  │
  ├─ Adaki::CaptainUsageTracker.record! (audit log + counter)
  │
  ▼
process_response
  │
  ├─ JSON parse falla → @response['response'] = nil
  │   → validate_message_content! raises
  │   → rescued en perform → handle_error
  │     → process_v1_handoff IF conversation_pending?
  │       (si conv ya está open: SILENCIO)
  │
  ▼
create_messages → mensaje saliente
```

## Cheat-sheet de diagnóstico

```ruby
account = Account.find(<ID>); inbox = account.inboxes.find(<INBOX_ID>)

# Capa 1
account.usage_limits[:captain][:responses]
# => { total_count:, current_available:, consumed: }

# Capa 2
account.adaki_captain_monthly_limit
Adaki::CaptainUsage.current_for(account).request_count

# Capa 3
inbox.captain_active?
inbox.captain_assistant&.autopilot_enabled?

# Forzar el job para ver el error real
conv = inbox.conversations.last
Captain::Conversation::ResponseBuilderJob.new.perform(conv, inbox.captain_assistant)
```
