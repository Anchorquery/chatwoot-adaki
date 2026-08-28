# Captain — Referencias técnicas para la remediación

Fecha: 2026-08-26. Compilado a partir de: lectura directa del código fuente de las
gemas instaladas (`ruby_llm-1.15.0`, `ai-agents-0.10.0` en
`C:\Ruby344-x64\lib\ruby\gems\3.4.0\gems\`), documentación oficial de Google/OpenAI,
y código fuente + issues de Evolution API. Complementa a `captain-remediacion.md`.

---

## 1. RubyLLM 1.15.0 (motor de V1 y transporte de V2)

### Configuración relevante (`lib/ruby_llm/configuration.rb:35-57`)

| Opción | Default | Nota |
|---|---|---|
| `request_timeout` | **300 s** | Único timeout; no hay `open_timeout` separado |
| `max_retries` | 3 | Reintentos Faraday |
| `retry_interval` | **0,1 s** | Con `backoff_factor: 2` → 0,1/0,2/0,4 s. Absurdo para un 429; subir a 1-2 s |
| `retry_backoff_factor` | 2 | |
| `retry_interval_randomness` | 0,5 | Jitter |
| `default_model` | `gpt-5.4` | |

- `RubyLLM.configure` muta un **singleton global** sin locks. Cambiar **API keys** en
  caliente SÍ afecta a chats vivos (los providers leen la key en cada request);
  cambiar **timeout/retries/api_base** NO — están congelados en la conexión Faraday:
  hay que reconstruir el `Chat`.
- `RubyLLM.logger` y `Models.instance` están memoizados: no se recargan.
- `RubyLLM.context` hace `config.dup` (copia superficial) — aislamiento efectivo para
  valores escalares. No hay pooling de conexiones; cada Chat/with_context crea una
  conexión Faraday nueva.
- **`RubyLLM.with_thread_context` NO existe en la gema**: es un parche del fork
  (`config/initializers/ruby_llm_thread_context.rb`) que hace `prepend` sobre
  `Chat#initialize`. Añadir test de contrato contra la firma
  `(model:, provider:, assume_model_exists:, context:)`.

### Jerarquía de errores y mapeo HTTP (`lib/ruby_llm/error.rb`)

| HTTP | Excepción | ¿La gema la reintenta? |
|---|---|---|
| 400 | `BadRequestError` (o `ContextLengthExceededError` si el mensaje matchea patrones de contexto) | No |
| 401 | `UnauthorizedError` | No |
| 402 | `PaymentRequiredError` | No |
| 403 | `ForbiddenError` | No |
| 429 | `RateLimitError` (o `ContextLengthExceededError` por patrón) | **Sí** |
| 500 | `ServerError` | **Sí** |
| 502/503/504 | `ServiceUnavailableError` | **Sí** |
| 529 | `OverloadedError` (Anthropic) | **Sí** |
| otros (404/422/…) | `RubyLLM::Error` genérico | No |

- `ConfigurationError` NO hereda de `RubyLLM::Error` (falta key → salta **eager en
  `Chat.new`**, no en `ask`).
- También reintenta: `Errno::ETIMEDOUT`, `Timeout::Error`, `Faraday::TimeoutError`,
  `Faraday::ConnectionFailed` (`connection.rb:102-114` — usar esta lista como fuente
  de verdad de "transitorio").
- El middleware de retry **incluye `:post`** (`connection.rb:83`): las completions se
  reejecutan (no idempotentes de cara a facturación). Respeta `Retry-After` si viene.
- Peor caso actual: timeout 300 s × reintentos ≈ **20 min por llamada**.
- Un `RateLimitError` que llega al caller **ya agotó** los 3 reintentos de Faraday.

### Tools (`lib/ruby_llm/tool.rb`)

- `execute(**kwargs)` — solo keywords. Errores de keywords (falta/sobra) se devuelven
  al modelo como hash `{error: ...}` SIN lanzar; **cualquier otra excepción se
  propaga** y aborta la conversación (ni `Tool#call` ni `Chat#execute_tool` tienen
  rescue). Mecánica exacta del hallazgo C5: un `execute` con posicional requerido
  (firma `Agents::Tool`) lanza `ArgumentError` de aridad → handoff.
- Tool inexistente llamado por el modelo → hash de error al modelo, no excepción.
- `Tool::Halt`: corta el loop; `ask` devuelve el `Halt` (clave para entender la fuga
  de handoff, §2).

### Proveedor Gemini — trampas

- **Gemini NO tiene mapeo de errores propio**: usa el genérico por HTTP status y
  descarta el campo `status` de Google (`RESOURCE_EXHAUSTED`, etc.). Consecuencias:
  - **Key inválida de Gemini = HTTP 400** (`API_KEY_INVALID`) → llega como
    `BadRequestError`, ¡no `UnauthorizedError`! El clasificador debe inspeccionar
    `error.response.body` buscando `API_KEY_INVALID`.
  - **429 ambiguo**: rate-limit y cuota agotada del proyecto llegan ambos como
    `RateLimitError` y se reintentan. Distinguir por body si importa.
- Mensajes `role: :system` se envían como `'user'` (no usa `systemInstruction`).
- Los `tool_call.id` son UUIDs locales; la correlación resultado↔llamada es **por
  nombre de función**. Al implementar la ventana de historial (Fase 1b): cortar solo
  en fronteras que mantengan juntos el assistant-con-tool_calls y sus mensajes tool
  (el restore de ai-agents ya descarta tool-messages huérfanos con warning).
- 2.5-flash: `responseJsonSchema` estándar; `flash-lite` se considera sin function
  calling por regex de capacidades.

---

## 2. ai-agents 0.10.0 (runtime Captain V2)

### Configuración

- `Agents.configure` **vuelca todo sobre la config GLOBAL de RubyLLM** — no mantiene
  config propia para los chats. `Agents::Configuration` NO expone `max_retries`
  (tocar vía `RubyLLM.configure`). Default propio: `request_timeout = 120`,
  `default_model = "gpt-4o-mini"`.
- El Runner crea el chat **sin contexto** (`RubyLLM::Chat.new(model:)`,
  `runner.rb:106`) → usa la config global. Por eso existe el parche
  `with_thread_context` del fork.
- Credencial ausente revienta eager en `Chat.new` con `ConfigurationError`.

### max_turns — corrección importante al plan

- `DEFAULT_MAX_TURNS = 10`; el fork pasa `max_turns: 100`.
- **`max_turns` NO limita llamadas al LLM ni ejecuciones de tools.** Solo cuenta
  vueltas del bucle del Runner, que en la práctica se incrementan por **handoff**
  entre agentes. Todo el loop de tools ocurre DENTRO de un `chat.complete` que
  recursiona internamente. No existe ningún timeout de ejecución en la gema.
- ⇒ Para presupuestar de verdad (Fase 3): contador de llamadas LLM en
  `on_chat_created` + `chat.on_end_message`, y/o abortar desde dentro de un tool.
  Los callbacks del CallbackManager **tragan excepciones** (no sirven para abortar).
- Al superar `max_turns`: `RunResult` con `error: MaxTurnsExceeded` **y**
  `output: "Conversation ended: Exceeded maximum turns: N"` — output NO nil, en
  inglés. **Filtrar antes de enviar al cliente** (fuga potencial nueva).

### RunResult y tokens — corrección al diseño de contabilidad

- `result.usage` **subcontabiliza sistemáticamente**: solo suma la respuesta final de
  cada vuelta del Runner; los mensajes assistant intermedios del loop de tools nunca
  pasan por `Usage#add`, y un turno que acaba en handoff (`Tool::Halt`) suma **cero**.
- Con error antes de la primera respuesta: usage = 0/0/0 y `error` poblado (lo que
  vimos en producción — no es bug del fork).
- **Única fuente fiable de tokens por llamada**:
  `runner.on_chat_created { |chat, ...| chat.on_end_message { |msg| acumular(msg.input_tokens, msg.output_tokens) } }`
  — patrón exacto de `instrumentation/tracing_callbacks.rb:69-76`. Este es el punto
  de enganche para la contabilidad Adaki en V2 (Fase 4).

### Errores

- El Runner captura **todo `StandardError`** → `result.error`, `output: nil` (salvo
  MaxTurnsExceeded, ver arriba). Clasificar por `error.class` (jerarquía RubyLLM) +
  `error.response&.status`/body.
- Excepción dentro de un tool: el wrapper emite `tool_complete` con "ERROR: ..." y
  **re-lanza** → aborta el run. Tools deben capturar internamente y devolver string.
- La gema no reintenta nada; el único retry es el de Faraday/RubyLLM.

### Handoffs — origen exacto de la fuga C12

- `HandoffTool#perform` marca `context[:pending_handoff]` y devuelve
  `halt("I'll transfer you to #{target} who can better assist you with this.")`
  (`handoff.rb:84`).
- Dos vías de fuga al cliente:
  1. Ese texto se persiste como mensaje `role: :tool` en el historial; el agente
     destino lo ve como contexto y **lo parafrasea** ("Se ha transferido la
     conversación al agente de información de productos" = traducción del LLM).
  2. Si llega un `Halt` sin `pending_handoff` (race documentada en el código, o
     cualquier tool que use `halt`), `runner.rb:185-187` devuelve el texto del halt
     **directamente como output** al cliente.
- La gema trae `RECOMMENDED_HANDOFF_PROMPT_PREFIX` ("do not mention these
  transfers") pero **nunca lo aplica sola** — hay que anteponerlo a las instructions.
- Mitigación (Fase 4): aplicar el prefix + filtrar del historial reinyectado los
  tool-messages de handoff + guard sobre el output que matchee anuncios de
  transferencia.

### Callbacks disponibles

`on_run_start`, `on_agent_thinking`, `on_chat_created(chat, agent, model, ctx)`,
`on_llm_call_complete` (una vez por vuelta, NO por llamada HTTP),
`on_tool_start/complete`, `on_agent_handoff`, `on_agent_complete`,
`on_run_complete`. Tolerantes a aridad; nunca abortan el run.

---

## 3. APIs de proveedor

### Gemini (generativelanguage.googleapis.com, v1beta)

| HTTP | Status | ¿Retry? |
|---|---|---|
| 400 `INVALID_ARGUMENT` (incluye **key inválida**, reason `API_KEY_INVALID`) | permanente | No |
| 400 `FAILED_PRECONDITION` (región/billing) | permanente | No |
| 403 `PERMISSION_DENIED` (key válida pero restringida) | permanente | No |
| 404 | permanente | No |
| 429 `RESOURCE_EXHAUSTED` (rate limit O cuota) | transitorio* | Sí, backoff |
| 500 `INTERNAL` (a menudo contexto enorme) | semi | 1 vez |
| 503 `UNAVAILABLE` | transitorio | Sí |
| 504 `DEADLINE_EXCEEDED` | presupuesto | No a ciegas: reducir contexto |

Regla oficial: reintentar solo 429/408/5xx con backoff exponencial (1→2→4→8 s) +
jitter; nunca 400/403.

- **Validación de key**: `GET /v1beta/models?key=K` — gratis; 200 = viva,
  400 `API_KEY_INVALID` = muerta, 403 = viva pero restringida.
- `gemini-2.5-flash`: 1.048.576 tokens entrada / 65.536 salida. Precio pago:
  $0,30/M entrada, **$2,50/M salida (thinking incluido)**. Rate limits: ya solo en
  la consola de AI Studio por proyecto (tiers Free/1/2/3 + tope de gasto en ventana
  de 10 min).
- **Sigue vigente en 2.5**: no se puede combinar `tools` con
  `responseMimeType/responseSchema` en la misma llamada (structured-output-with-tools
  es solo serie Gemini 3). El workaround del repo sigue siendo necesario.

### OpenAI

| HTTP | code | ¿Retry? |
|---|---|---|
| 401 `invalid_api_key` | No |
| 403 región | No |
| 429 rate limit | Sí — respetar `Retry-After` |
| 429 **`insufficient_quota`** | **No** (billing; permanente) |
| 500 / 503 | Sí |

- Validación: `GET /v1/models` con Bearer — 200 viva, 401 muerta.
- **El 429 de OpenAI no es homogéneo**: distinguir por `error.code`.

### Síntesis para `Captain::FailurePolicy` (Fase 2)

- `configuration` (permanente, abre circuito): OpenAI 401; Gemini 400 con
  `API_KEY_INVALID` en el body; 402/403; OpenAI 429 `insufficient_quota`;
  `RubyLLM::ConfigurationError`.
- `transient` (re-lanzar → retry Sidekiq): `RateLimitError` (¡ya vino reintentado por
  Faraday!), `ServerError`, `ServiceUnavailableError`, `OverloadedError`, timeouts de
  red.
- `budget` (ni retry ni ciego): `ContextLengthExceededError`, 504 — reducir contexto
  (síntoma de que falta la ventana de historial de Fase 1b).
- `model`: JSON malformado / respuesta vacía → 1 reintento inmediato.

---

## 4. Evolution API v2 × Chatwoot (proyecto renombrado a Evolution Foundation)

### Opciones de `POST /chatwoot/set/{instance}`

`enabled, accountId, token, url, signMsg, signDelimiter, reopenConversation,
conversationPending, nameInbox, mergeBrazilContacts, importContacts, importMessages,
daysLimitImportMessages, autoCreate, organization, logo, ignoreJids, number`.

- `reopenConversation: true` + `conversationPending: true` = cada mensaje entrante
  reabre la conversación en `pending` — el mecanismo exacto del hallazgo O8.
- `organization`/`logo` = nombre e imagen del **contacto de comandos del bot** (el
  +123456).

### El contacto +123456

- **Hardcodeado** en `chatwoot.service.ts` (`findContact(instance, '123456')`). Canal
  de: QR, "Connection successfully established", `status.instance`, avisos de import,
  y comandos entrantes (`/init`, `/status`, `/disconnect`, `/clearcache`).
- Interruptor oficial: **`CHATWOOT_BOT_CONTACT=false`** (variable de entorno,
  **global al servidor**, default `true`, requiere reinicio). Solo documentado en
  `.env.example`.
- ⚠️ Caveat de código: `createBotMessage` no consulta la flag — solo falla si no
  encuentra el contacto. Si el +123456 **ya existe** en Chatwoot, los avisos siguen
  llegando: hay que **borrar el contacto** además de poner la variable.
- Coste de desactivarlo: se pierde el QR y los comandos desde Chatwoot (usar el
  Manager/API de Evolution).
- **`ignoreJids` NO filtra al bot**: solo aplica a mensajes reales de WhatsApp
  (`eventWhatsapp`); los avisos del bot entran directo por la API de Chatwoot.
  Formato: array de strings; literales `'@g.us'` (todos los grupos) y
  `'@s.whatsapp.net'` (todos los individuales), o JID exacto. Sin wildcards.
- El webhook configurable por instancia tampoco controla estos avisos (van por otra
  vía en proceso).
- Issue upstream [EvolutionAPI#1603] — exactamente este problema, cerrado sin
  solución oficial; la comunidad filtra en el lado del bot. **Valida la guarda de
  Fase 1 como defensa primaria.**
- Throttling reciente en Evolution: avisos "connected" no-QR limitados a 1 cada 30 s.

---

## 5. Sidekiq 7.3.1 / colas

- `config/sidekiq.yml`: colas **sin pesos ⇒ prioridad estricta** (una cola inferior
  solo se procesa si las superiores están vacías). `ResponseBuilderJob` va a
  `default` (4ª); concurrencia global 10.
- Riesgo actual: jobs LLM largos ocupan los 10 hilos de `default` y matan de hambre a
  `mailers`, `low`, `scheduled_jobs`…
- Herramienta correcta (disponible desde Sidekiq 7.0): **capsules** — un capsule
  `captain` con `concurrency: 2-3` para la cola dedicada, aislando el impacto de un
  incidente del proveedor. Configuración en el initializer
  (`config.capsule("captain") { |c| c.concurrency = 2; c.queues = %w[captain] }`).
- ActiveJob `retry_on` (para la clase `transient` de la FailurePolicy):
  `retry_on Captain::TransientProviderError, wait: :polynomially_longer, attempts: 3`
  — el reintento vive aquí, no en Faraday (bajar `max_retries` de RubyLLM a 1).

---

## 6. Correcciones al plan de remediación derivadas de esta investigación

1. **Fase 3**: ~~bajar `max_turns` NO acota el loop de tools (solo handoffs)~~ —
   **corregido tras releer el código fuente instalado** (`ai-agents-0.10.0/lib/
   agents/runner.rb#run`, verificado en la implementación de Fase 3,
   2026-08-26): `current_turn` se incrementa en cada iteración del loop
   principal, incluidas las continuaciones por tool-call y los handoffs —
   `max_turns` SÍ acota el presupuesto completo de llamadas LLM/tool por sí
   solo. El contador manual vía `on_chat_created`/`on_end_message` propuesto
   aquí habría sido complejidad redundante; se implementó solo bajar
   `max_turns` de 100 a 10 (`Captain::Assistant::AgentRunnerService::MAX_TURNS`).
   Ver `captain-remediacion.md` §Fase 3 para el detalle completo, incluida la
   verificación de que la fuga en inglés de `MaxTurnsExceeded` tampoco existe
   en el código actual (la intercepta `process_agent_result` vía
   `result.error` antes de leer `result.output`).
2. **Fase 2**: el clasificador necesita inspección de body para Gemini
   (`API_KEY_INVALID` llega como 400/`BadRequestError`) y para el 429 de OpenAI
   (`insufficient_quota` es permanente).
3. **Fase 4 / C12**: origen de la fuga identificado (texto del `halt` de la gema,
   parafraseado por el LLM o devuelto directo). Mitigación triple: prefix
   recomendado + filtrado del historial + guard de salida. Nueva fuga a filtrar:
   el output en inglés de `MaxTurnsExceeded`.
4. **Fase 4 / contabilidad**: usar el hook `on_end_message`, no `result.usage`
   (subcontabiliza).
5. **Fase 1b**: la ventana de historial debe cortar sin separar assistant-tool_calls
   de sus tool-results (correlación por nombre en Gemini; el restore ya descarta
   huérfanos).
6. **Fase 1 (Evolution)**: la defensa externa es `CHATWOOT_BOT_CONTACT=false` +
   borrar el contacto; `ignoreJids` no sirve. La guarda en Chatwoot sigue siendo la
   primaria (issue #1603 lo confirma).
7. **Test de contrato** para el parche `with_thread_context` (se rompe en silencio si
   cambia la firma de `Chat#initialize` al actualizar la gema).
