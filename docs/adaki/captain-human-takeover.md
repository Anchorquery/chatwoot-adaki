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
- `human_takeover_active_thread_days` — entero ≥ 0, default **0** (desactivado);
  solo aplica si modo = `after_window`. Ver "Hilo humano activo".

## Hilo humano activo (`human_takeover_active_thread_days`)

**Problema:** la ventana de minutos no distingue "un agente intervino una vez"
de "un agente lleva una semana atendiendo". Con `after_window` y una ventana de
1440 min, si el cliente tarda 42 h en contestar a un agente que lleva días con
él, el bot retoma el hilo aunque el cliente se dirija al agente por su nombre.
Es comportamiento configurado, no un bug de la ventana.

**Regla:** con modo `after_window`, el hilo sigue siendo humano (el bot calla)
aunque haya pasado `human_takeover_window_minutes` mientras se cumpla TODO:

1. conversación `open`;
2. con `assignee_id`;
3. existe una respuesta humana **pública** (outgoing, `sender_type=User`,
   `private=false`);
4. no hubo `conversation_resolved` posterior a esa respuesta (una reapertura
   tras resolver empieza de cero);
5. esa última respuesta humana es más reciente que N días.

Si falla cualquier punto, decide la ventana de minutos de siempre. En
particular: una asignación sin respuesta pública (solo notas privadas) sigue
cayendo en la ventana de minutos, y `pending` no cuenta como hilo activo.

**Qué no cambia:** `captain_handoff_pending?` se evalúa antes y sigue mandando;
`always` y `never` no pasan por la regla; la resolución libera el hilo; el bot
sigue respondiendo en conversaciones `open` sin assignee (modo Adaki).

**Cascada:** `CaptainInbox.settings` > `Captain::Assistant.config` > 0. Un
override explícito a `0` en la bandeja apaga la regla aunque el asistente la
tenga activa; `Heredar` (clave ausente) toma el valor del asistente.

**Recomendación:** dejar 0 por defecto y activar 7 solo en el asistente cuyas
bandejas gestionan hilos largos con agentes.

Implementación: `Captain::HumanTakeoverEvaluator#active_human_thread?`, que la
rama `after_window` de `bot_can_takeover?` consulta como
`!active_human_thread? && last_human_response_older_than_window?`.

### Nota sobre `Inbox#continue_bot_after_assignment?`

[app/models/inbox.rb](app/models/inbox.rb) define `continue_bot_after_assignment?`,
que lee el flag legacy de `Channel::WebWidget`. No tiene ningún llamador Ruby en
el repo (solo su definición, el flag del canal y `Settings.vue`): no es un
segundo criterio de takeover en la práctica. El único criterio es el evaluador.

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

## Bug relacionado: auto-handoff dispara en conversaciones de campaña

`Captain::InboxPendingConversationsResolutionJob` evaluaba TODAS las pending
conversations vencidas (`last_activity_at < cutoff`), incluyendo las creadas
por una campaña outbound. Resultado: a las N horas el bot mandaba el
"Auto-handoff: ..." y el `handoff_message` configurado (p. ej. "Gracias por
contactarnos. Te transfiero..."), aunque el cliente nunca abrió la conversación
ni interactuó — solo fue blanco de la campaña.

Fix: `resolvable_pending_conversations` ahora filtra `campaign_id: nil`,
alineado con la lógica que ya excluía campañas del envío de OOO post-handoff
([inbox_pending_conversations_resolution_job.rb](enterprise/app/jobs/captain/inbox_pending_conversations_resolution_job.rb#L57)).

Si una conversación nace de una campaña, su cadencia la maneja la campaña.
Captain no debe interferir hasta que el contacto responda — en cuyo momento
la conversación pasa a `open` y `pending` ya no aplica.

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
