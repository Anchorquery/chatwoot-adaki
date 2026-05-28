# Captain — Re-enganche del bot tras intervención humana

Define cuándo el bot vuelve a responder después de que un agente humano haya
participado en la conversación (asignándose o respondiendo). Sustituye al toggle
binario antiguo `continue_after_human_takeover` con modos configurables.

## Modos

| Modo | Comportamiento |
|---|---|
| `always` | Bot responde aunque humano haya respondido / esté asignado. Coexiste con humano. |
| `after_window` (default) | Bot retoma si la última respuesta humana fue hace > **N minutos**. Mientras humano responde activo, bot calla. |
| `never` | Humano queda dueño de la conversación. Bot no vuelve a responder. |

**Default:** `after_window` con ventana de **15 minutos**.

## Cascada de configuración

Igual que `auto_handoff_enabled` / `auto_resolve_hours`:

```
CaptainInbox.settings[<key>]   <-- override por bandeja (Heredar = unset)
  └── Captain::Assistant.config[<key>]   <-- valor del asistente
        └── Default global (after_window / 15)
```

Keys involucradas:

- `human_takeover_mode` — enum `always` / `after_window` / `never`
- `human_takeover_window_minutes` — entero positivo (solo aplica si modo = `after_window`)

## Compatibilidad con toggle legacy

El campo legacy `continue_after_human_takeover` sigue persistido. Mapeo
implícito cuando `human_takeover_mode` está unset en el assistant:

| Legacy `continue_after_human_takeover` | Modo derivado |
|---|---|
| `true` o ausente | `after_window` (default nuevo) |
| `false` | `never` |

Si `human_takeover_mode` está set explícito, **gana sobre el legacy**.

## Implementación

**Evaluador centralizado:**
[enterprise/lib/captain/human_takeover_evaluator.rb](enterprise/lib/captain/human_takeover_evaluator.rb)

```ruby
Captain::HumanTakeoverEvaluator.new(conversation: conv).human_takeover?
# true  => bot debe ceder (NO responde)
# false => bot puede responder
```

Lógica de decisión:

1. Si no hay `assignee_id` y no existe ningún mensaje outgoing `sender_type=User`
   con `private=false` → `false` (no hay takeover). Bot responde.
2. Si hubo intervención humana → consulta `mode` cascadeado:
   - `always` → `false` (bot responde igual)
   - `after_window` → compara `created_at` máximo de respuestas humanas
     vs `N.minutes.ago`. Si más viejo, bot responde.
   - `never` / fallback → `true`. Bot calla.

**Consumidores:**

- [enterprise/app/services/enterprise/message_templates/hook_execution_service.rb](enterprise/app/services/enterprise/message_templates/hook_execution_service.rb#L95)
  — decide si encolar `Captain::Conversation::ResponseBuilderJob` al crearse
  un mensaje incoming.
- [enterprise/app/jobs/captain/conversation/response_builder_job.rb](enterprise/app/jobs/captain/conversation/response_builder_job.rb#L219)
  — re-evalúa antes de generar la respuesta (la conversación pudo cambiar
  entre encolado y ejecución).

**Modelos:**

- [enterprise/app/models/captain/assistant.rb](enterprise/app/models/captain/assistant.rb)
  expone `human_takeover_mode_value`, `human_takeover_window_minutes_value`
  y la constante `HUMAN_TAKEOVER_MODES`.
- [enterprise/app/models/captain_inbox.rb](enterprise/app/models/captain_inbox.rb)
  cascadea overrides por bandeja con la misma firma.

**Controllers:**

- Assistants — permite `config.human_takeover_mode`, `config.human_takeover_window_minutes`
  ([assistants_controller.rb](enterprise/app/controllers/api/v1/accounts/captain/assistants_controller.rb)).
- Captain inboxes override — permite las mismas keys dentro de `settings`
  ([inboxes_controller.rb](enterprise/app/controllers/api/v1/accounts/captain/inboxes_controller.rb)).

**API payload:**

`GET /api/v1/accounts/:id/captain/assistants/:aid/inboxes` devuelve:

```json
{
  "captain_inbox": {
    "settings": { "human_takeover_mode": "always" },
    "effective": {
      "human_takeover_mode": "always",
      "human_takeover_window_minutes": 15
    }
  }
}
```

`effective` siempre trae el valor final tras cascada (override > assistant > default).

## UI

- **Asistente** — `Captain → Asistentes → Configuración del sistema`:
  selector de modo + input de minutos (solo visible si modo = `after_window`).
- **Bandeja override** — `Captain → Asistentes → Bandejas conectadas → ⚙`:
  mismos campos con opción `Heredar` para limpiar el override.

i18n: claves `CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.*` y
`CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_WINDOW.*` en ES + EN.

## Caso de uso resuelto

**Problema previo:** un cliente escribía, el bot respondía, un agente intervenía
para resolver una duda puntual. Días después el cliente volvía a escribir y el
bot ya no respondía porque `human_response_exists?` quedaba `true` para siempre.
El toggle binario `continue_after_human_takeover` no resolvía la mezcla
deseada (humano activo gana, pero cliente recurrente vuelve al bot).

**Resolución:** modo `after_window` con ventana de 15 minutos. Mientras el
agente chatea activo, bot calla. Cuando el cliente regresa horas o días
después, la última respuesta humana es vieja y el bot retoma automáticamente.

## Bug relacionado: falsa detección de grupo en Channel::Api

Durante la investigación se detectó que `Conversation#group?` retornaba `true`
para conversaciones 1:1 cuando el inbox es de tipo `Channel::Api` (Evolution
WhatsApp bridge). Causa: `group_structured_identifier?` aplicaba la heurística
"más de 15 dígitos = grupo" sobre `contact_inbox.source_id` que en API channel
es un UUID. `UUID.gsub(/\D/, '')` produce 32 dígitos hex → falso positivo.

Fix: rechazar identificadores con letras antes de la heurística numérica
([conversation.rb](app/models/conversation.rb#L295)). JIDs WhatsApp legítimos
son 100% numéricos (modernos) o `digits-digits` (legacy); cualquier letra
descarta el candidato.

Síntoma observado: el bot ignoraba todos los mensajes incoming en inboxes API
porque el Hook entraba al branch `conversation.group?` y exigía mención del
bot que nunca llegaba.

## Migración

Ninguna. Defaults cubren todos los registros existentes:

- Assistants con `continue_after_human_takeover` true / unset → comportan como
  `after_window` (15 min).
- Assistants con toggle `false` → comportan como `never` (idéntico al
  comportamiento previo).

Para cambiar modo en un assistant existente sin frontend:

```ruby
a = Captain::Assistant.find(<id>)
a.update!(config: a.config.merge(
  'human_takeover_mode' => 'after_window',
  'human_takeover_window_minutes' => 30
))
```

Para override por inbox:

```ruby
ci = CaptainInbox.find_by!(inbox_id: <inbox_id>)
ci.update!(settings: ci.settings.merge(
  'human_takeover_mode' => 'always'
))
```
