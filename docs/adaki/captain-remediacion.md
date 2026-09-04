# Captain — Diagnóstico consolidado y plan de remediación

Fecha: 2026-08-26. Origen: investigación completa del reporte "el Captain se pega y
siempre manda al agente". Todo lo listado como **verificado** fue reproducido contra
producción (logs de Sidekiq, consultas a BD vía `rails runner`, pruebas HTTP contra
los proveedores) o leído directamente en el código con ruta y línea.

---

## 1. Inventario de hallazgos

### 1.1 Estado operativo (config/datos, verificado en producción)

| # | Hallazgo | Evidencia | Impacto |
|---|----------|-----------|---------|
| O1 | Key global de OpenAI (`installation_configs.CAPTAIN_OPEN_AI_API_KEY`, `...po0A`) **revocada** | HTTP 401 contra `api.openai.com`; 164 chars, sin whitespace | Toda cuenta sin credencial propia tiene el bot roto |
| O2 | Cuenta 1 (Adaki) y cuenta 4 (Silnatur) **sin credencial propia** → heredan O1 | `Platform::Models::Resolver` → nil → fallback global | Cuenta 1: handoff en cada mensaje (reproducido 17:13 UTC). Cuenta 4: bomba latente |
| O3 | Credencial 2 (cuenta 2, OpenAI, misma key `...po0A`) en estado `revoked` pero su metadata dice `validation: active` (2026-06-01) | Consulta a `platform_credentials` | La metadata de validación miente; nadie revalida tras revocar |
| O4 | Key global de Gemini **vacía**; las únicas keys vivas son las Gemini de cuentas 2 y 3 (HTTP 200) | Prueba directa contra ambos proveedores | No existe fallback global funcional |
| O5 | Cuentas 2 y 3 resuelven modelo por `via: :any_enabled` — **ningún modelo asignado por feature** | Salida del Resolver | El bot usa "el primer modelo habilitado", no el elegido para la tarea |
| O6 | **89,7% del tráfico entrante** de la cuenta 3 (410 de 457 mensajes) son avisos de sistema de Evolution ("Connection successfully established", "QRCode generated", "import messages", "instance status") publicados como mensajes de cliente desde el contacto de servicio (`+123456`, `identifier` nil, `source_id` nil) | Conteo en BD + volcado de conversaciones 119/140 | El bot lleva meses respondiendo a una máquina 5-7 veces/día; al menos un handoff falso a humano provocado por un error de importación |
| O7 | La instancia de WhatsApp se **reconecta cada 1-3 horas** (madrugada incluida) | Timestamps de los avisos de conexión en conv 140 | Problema de infraestructura independiente; cada reconexión = 1 llamada LLM |
| O8 | Evolution resetea la conversación a `pending` en cada mensaje entrante (`toggle_status` desde la integración) | Logs de Rails 17:11:16 | Reabre la puerta al handoff en cada mensaje; el ciclo se repite indefinidamente |

Discriminador verificado para tráfico de máquina: mensajes con `source_id` nulo y
contacto con `identifier` nulo / teléfono `+123456`; los clientes reales traen
`source_id: "WAID:..."` e `identifier: "<num>@s.whatsapp.net"`. Para la guarda usar la
señal del **contacto**, no la del mensaje (un `source_id` nulo puede ser legítimo en
otras integraciones API).

### 1.2 Defectos de código (verificados por lectura + reproducción)

| # | Defecto | Dónde | Consecuencia |
|---|---------|-------|--------------|
| C1 | **Todo fallo → handoff** indistinguible de una escalación real: `handle_error` convierte cualquier `StandardError` en `process_v1_handoff`; el runner V2 traga errores y devuelve el token `conversation_handoff` | `response_builder_job.rb#handle_error`, `agent_runner_service.rb#llm_error_response/#error_response` | Una key muerta se presenta al cliente igual que "te paso con un especialista". Si la conversación ya está `open`, ni handoff: silencio total ("se pega") |
| C2 | Config LLM **congelada por proceso**: `ai_agents.rb` fija la key del runner V2 en el boot; `Llm::Config` memoiza; `reset!` solo actúa en el proceso que guardó el cambio | `config/initializers/ai_agents.rb`, `lib/llm/config.rb`, `installation_config.rb:72-76` | Rotar la key exige reiniciar contenedores; el comentario "no container restart needed" es falso para Sidekiq |
| C3 | **Sin `strip`** de las keys en ningún punto de lectura | `lib/llm/config.rb#provider_values`, adapter legacy, initializer | Un espacio/salto pegado en Super Admin = "Incorrect API key" con key válida |
| C4 | **Sin presupuesto de ejecución**: `request_timeout` default 300 s, 3 reintentos Faraday que incluyen POST, `max_turns: 100` en el loop agéntico, jobs en cola `default`, y el `rescue` no re-lanza (Sidekiq no reintenta) | Gema `ruby_llm` 1.15.0 defaults; `agent_runner_service.rb:73`; `response_builder_job.rb:25-26` | Un incidente del proveedor puede colgar un job ~15 min y saturar la cola compartida; reproducidos 105 s para un "Hola" con key muerta |
| C5 | ✅ **Tools V1 incompatibles**: `RegistryService` inyecta tools con firma `Agents::Tool` (`execute(tool_context, **params)`) en el `RubyLLM::Chat` plano de V1, que llama `execute(**args)` | `assistant_chat_service.rb:36-39` vs `ruby_llm` `tool.rb` | En V1 cualquier intento del LLM de usar FAQ/handoff-tool → `ArgumentError` → handoff silencioso. Solo `search_documentation` funciona. **Re-verificado con ejecución real de Ruby antes de tocar código (2026-08-26)**: `Foo.new.execute(**{a:1})` contra un método `execute(tool_context, **params)` sí produce `ArgumentError: wrong number of arguments (given 0, expected 1)` — confirma el hallazgo al 100%, a diferencia de la corrección hecha en Fase 3 sobre `max_turns`. Arreglado en Fase 4, ver más abajo |
| C6 | Señales de handoff **duplicadas y frágiles**: string mágico `conversation_handoff`, flag `handoff_tool_called` (solo V2), clasificador V1 — tres mecanismos para el mismo hecho | `response_builder_job.rb:108-122` | Un `bot_handoff!` ejecutado por tool en V1 pasaría desapercibido y el job postearía encima |
| C7 | `HumanTakeoverEvaluator`: assignee presente sin respuesta humana → bot mudo **para siempre** (sin temporizador de escape); cadena handoff → `open` → auto-asignación → mute | `human_takeover_evaluator.rb:79` | Un solo fallo silencia el bot en esa conversación de forma permanente |
| C8 | `pg_advisory_xact_lock` **bloqueante y sin timeout** por cuenta en el hot path de cada llamada LLM (cadena de auditoría Adaki) | `audit_logger.rb:49-79`, invocado desde `captain_usage_tracker.rb#record!` | Serializa todas las respuestas Captain de una cuenta; una transacción atascada las cuelga todas |
| C9 | Carrera de fin de mes: `Adaki::CaptainUsage.current_for` usa `find_or_create_by!` contra índice único `(account_id, period)` | `captain_usage.rb:9-11` | `RecordNotUnique` bajo concurrencia el día 1 → C1 → handoff |
| C10 | ✅ Contabilidad Adaki incoherente: ~~cuenta por round de tool-call (3-5 unidades por mensaje)~~ **corregido tras re-verificar (2026-08-26)**: `request_chat_completion` se llama exactamente una vez por `generate_response` (2 call sites en todo el repo, sin recursión) — el conteo de *solicitudes* ya era correcto; lo que sí se confirmó real: **no aplica en V2** (el runner no pasa por `ChatHelper`) y los tokens registrados son siempre 0 en V1 (`build_response` devuelve el hash JSON ya parseado, no el `RubyLLM::Message` con `.input_tokens`) | `chat_helper_adaki.rb` | El límite mensual configurado nunca se agotaba en V2 (invisible) y en V1 la auditoría de tokens no servía (siempre 0/0). Arreglado en Fase 4, ver más abajo |
| C11 | `ConversationCompletionService` es **fail-open hacia handoff**: cualquier error de API/parseo → `complete: false` → handoff masivo del cron de pendientes | `conversation_completion_service.rb:16,27,47` + `inbox_pending_conversations_resolution_job.rb:52` | Un incidente del proveedor convierte el cron en una máquina de handoffs |
| C12 | **Fuga de mensajes internos** al cliente: "Se ha transferido la conversación al agente de información de productos" pese a que el prompt lo prohíbe dos veces | Observado en conv 120; `assistant.liquid:2,11` | El enforcement vive solo en prompt; no hay filtro de salida |
| C13 | Trampa de cuota de plan: `CAPTAIN_CLOUD_PLAN_LIMITS` con JSON + `plan_name` ausente/sin match → límite 0 → handoff hardcodeado **en inglés** en cada mensaje | `plan_usage_and_limits.rb:87-108`, `hook_execution_service.rb:56-68` | Config-side foot-gun documentado en `captain-limits.md`; no activo hoy pero latente |
| C14 | **`spec/enterprise/` nunca corre en CI** (el workflow lo borra antes de rspec) | `.github/workflows/run_foss_spec.yml`; documentado en `captain-limits.md` | Meta-causa: todos los defectos anteriores pudieron vivir meses sin detección |

### 1.3 Calidad de cara al usuario final (segunda pasada, 2026-08-26)

Auditoría específica de "¿qué recibe el cliente?". El bot responde bien cuando todo
está sano, pero hay defectos que degradan las respuestas o filtran contenido:

| # | Hallazgo | Evidencia | Impacto en el usuario |
|---|----------|-----------|----------------------|
| Q1 | **Historial ilimitado al LLM**: `collect_previous_messages` (V1) y `build_context` (V2) envían TODOS los mensajes no privados de la conversación, sin ventana. La constante `MAX_MESSAGE_LENGTH = 10_000` está declarada y **nunca se usa** (código muerto) | `response_builder_job.rb:82-98`, `agent_runner_service.rb:89-108`; la conv 140 lleva 375 mensajes por request | Coste creciente por mensaje, degradación de foco del modelo, y riesgo de overflow de contexto → `BadRequestError` → 3 reintentos → handoff |
| Q2 | **Los mensajes de agentes humanos entran como turnos del bot**: `determine_role` mapea todo `outgoing` a `assistant`, sin distinguir `sender_type` | `response_builder_job.rb:100-102`; en el trace real del 26/08 el contexto enviado a OpenAI incluía mensajes personales del Admin ("clave odoo master daniel test", listas de fútbol, números de teléfono) como si el bot los hubiera dicho | El modelo "cree" haber dicho lo que dijo el humano → respuestas contaminadas por contenido ajeno al negocio, y **fuga de mensajes privados del operador al proveedor LLM** |
| Q3 | `temperature`: el default `\|\| 1` es código muerto (`nil.to_f` → `0.0`, nunca nil), y las cuentas reales tienen `temperature: 1` explícito | `chat_helper.rb:132-134`; config de asistentes de cuentas 1 y 3 | Temperatura 1 en un bot de soporte = variabilidad innecesaria; para respuestas factuales conviene 0.2-0.4 |
| Q4 | `feature_citation: true` en asistentes que responden por **WhatsApp**: el prompt exige citas `[[n](URL)]`, formato que WhatsApp no renderiza | `system_prompts_service.rb:207-216`; config de asistentes 1 y 3 | El cliente puede recibir texto con markdown roto y URLs internas de la KB expuestas |
| Q5 | **Saludo repetido**: "Start by introducing yourself" vive en el system prompt de CADA turno, sin guard anti-repetición | `system_prompts_service.rb:248`; conv 140: 35 veces el mismo saludo de 156 chars; conv 122: dos saludos seguidos a un usuario real | El bot se re-presenta ante mensajes cortos en vez de continuar la conversación |
| Q6 | Fuga del anuncio interno de transferencia entre escenarios (= C12) | Conv 120: "Se ha transferido la conversación al agente de información de productos" | El cliente ve maquinaria interna y pierde un turno |
| Q7 | **Cobertura de KB sin auditar**: el prompt ordena handoff cuando no encuentra información en documentos/FAQs; no hemos medido cuántos docs/FAQs tiene el asistente de producción (el comando quedó truncado) | `assistant.liquid:85-90` | KB pobre = handoffs "legítimos" evitables; pendiente de medir |

### 1.4 Hallazgos iniciales que faltaban en este documento

De la primera pasada de investigación, cinco quedaron fuera del inventario:

| # | Hallazgo | Dónde | Estado |
|---|----------|-------|--------|
| E1 | Clasificador V1 (`captain_v1_action_classifier`, ON por default) corre tras CADA respuesta V1 y puede forzar `action: handoff` por su cuenta | `v1_action_classifier.rb`, `assistant_action_classifier_service.rb` | Riesgo de sobre-handoff en cuentas V1; muere con V1 en Fase 4 |
| E2 | Rate limit de grupos: máx 3 mensajes/5 min por usuario en grupos/broadcast; el 4º recibe aviso hardcodeado en español y el resto silencio | `hook_execution_service.rb` (FOSS) :12-25 | Silencio por diseño que se reporta como "se pega"; documentar, no cambiar |
| E3 | Filtro de privacidad de Evolution en modo allowlist: el mensaje ni llega a Chatwoot — sin fila de mensaje, parece bot colgado | Estado vive en Evolution, no en el repo | Primer chequeo cuando no existe la conversación; añadido al runbook |
| E4 | Audiencias: `ordered` es `order(:id)` — una audiencia vieja y amplia eclipsa a las nuevas específicas; matching usa `label_list` vivo mientras otras vistas usan `cached_label_list` | `captain_inbox_audience.rb`, `conversation.rb:316` | Enrutado al asistente equivocado; revisar si se usan audiencias |
| E5 | Tools MCP: `timeout_seconds` 20 s default (cap 60), llamadas en serie dentro del loop agéntico | `mcp_server.rb:47`, `mcp_tool.rb:23-27` | Un endpoint muerto cuelga el job minutos sin handoff; entra en los presupuestos de Fase 3 |

### 1.5 Lo que SÍ funciona (verificado, no tocar)

- Calidad conversacional con humanos (cuenta 3): respuestas concretas con precios,
  latencia p50/p90 de 2 s, cero promesas vacías ("déjame revisar…"), el retry
  anti-promesa de `agent_runner_service.rb:150` no ha hecho falta en 7 días.
- `human_takeover_mode: always` en el asistente de la cuenta 1 y `after_window` en
  producción: la cascada CaptainInbox → Assistant → default funciona.
- `auto_handoff` apagado en el inbox 8: el cron no está generando handoffs falsos.
- El fix de grupos falsos en `Channel::Api` (UUID ≠ grupo) y la exclusión de campañas
  del auto-handoff siguen correctos.

---

## 2. Causas raíz de arquitectura

Los 22 hallazgos anteriores se reducen a **cinco decisiones de diseño ausentes**:

1. **No existe taxonomía de fallos.** Hay una sola salida para todo error: handoff con
   el mensaje amable del asistente. Un fallo de configuración (permanente, del
   operador), uno transitorio (del proveedor) y una decisión legítima del modelo
   producen el mismo efecto visible. Por eso el diagnóstico costó días: el síntoma no
   apunta a la causa. (C1, C11, parte de C13)

2. **La configuración no tiene ciclo de vida.** Dos almacenes de credenciales (global
   legacy + por cuenta), herencia implícita y silenciosa, sin validación continua, sin
   invalidación cross-proceso, sin señal de salud en ninguna UI. Una key muere y nadie
   se entera hasta que un cliente recibe una transferencia. (O1-O5, C2, C3)

3. **La frontera con el canal no tiene contrato.** Evolution inyecta avisos de máquina
   como clientes, resetea estados, y el filtro de privacidad vive fuera del repo. El
   bot trata todo lo que cruza la frontera como una persona. (O6-O8)

4. **Dos runtimes conviven a medias.** V1 y V2 comparten tools con firmas
   incompatibles, señalizan el handoff de tres formas distintas y los límites Adaki
   solo existen en uno. Cada fix hay que pensarlo dos veces y probarlo en dos caminos.
   (C5, C6, C10)

5. **No hay presupuestos ni observabilidad de ejecución.** Timeouts de gema, reintentos
   multiplicados en tres capas (Faraday × job × loop agéntico), locks sin timeout,
   cola compartida, y ninguna métrica de "por qué el bot no respondió". (C4, C7, C8, C9)

Y por encima de todas: **C14**. Sin CI para `spec/enterprise/`, cualquier arreglo es
fe, no ingeniería.

---

## 3. Principios del diseño propuesto

- **Fallo ruidoso hacia el operador, amable hacia el cliente.** El cliente puede seguir
  recibiendo el handoff (si el bot no puede pensar, que atienda un humano), pero el
  sistema debe registrar la causa, avisar al admin y dejar de insistir.
- **Una credencial es explícita o no es.** Se elimina la herencia global implícita.
- **Contratos en las fronteras.** Lo que entra por un canal se clasifica
  (humano / servicio / sistema) antes de decidir si el bot participa.
- **Presupuestos explícitos.** Toda llamada externa tiene timeout, reintentos acotados
  en UNA capa, y cola propia.
- **Un runtime.** V2 es el camino; V1 se congela y se retira.
- **Nada se mergea sin spec ejecutado.** Y la fase final hace que "ejecutado" lo haga
  CI, no una persona.

---

## 4. Plan por fases

### Fase 0 — Operación, hoy, sin deploy (≈30 min, la hace el operador)

1. Crear credencial Gemini para la **cuenta 1** (y para la 4 cuando tenga asistentes)
   y habilitar modelos. Verificación: `Resolver.resolve(account: Account.find(1),
   feature: "assistant")` devuelve la credencial nueva; un "Hola" de prueba responde.
2. **Vaciar** `CAPTAIN_OPEN_AI_API_KEY` (una key muerta que "parece configurada" es
   peor que un campo vacío) o sustituirla por una válida si se quiere fallback global
   durante la transición.
3. Eliminar o rotar la credencial 2 (`revoked`, key muerta) para que el inventario
   diga la verdad.
4. Asignar modelos **por feature** en cuentas 2 y 3 (eliminar la resolución
   `:any_enabled`).
5. Abrir ticket de infraestructura: la instancia de WhatsApp se reconecta cada 1-3 h
   (O7) — revisar memoria/red del contenedor de Evolution. Independiente del bot.
6. Calidad inmediata sin código (Q3/Q4): bajar `temperature` de los asistentes a
   0.3 y apagar `feature_citation` en los que responden por WhatsApp. Ambos desde la
   UI del asistente.
7. Medir la KB del asistente de producción (Q7):
   `Captain::Assistant.where(account_id: 3).each { |x| puts({id: x.id, nombre: x.name, docs: x.documents.count, faqs: x.responses.count, escenarios: x.scenarios.enabled.count}.inspect) }`

### Fase 1 — Contrato de ingesta: el bot no habla con máquinas (primer PR) ✅ implementada

Detiene el 90% del gasto y los handoffs falsos de producción.

- Nuevo predicado con nombre en el flujo de plantillas:
  `conversation.service_channel_conversation?` — verdadero cuando el contacto es el
  contacto de servicio del canal (`identifier` nulo **y** teléfono en la lista de
  contactos de servicio del inbox; default `["+123456"]` para `Channel::Api`/Evolution,
  configurable en `captain_inboxes.settings['service_contact_numbers']`).
- `Enterprise::MessageTemplates::HookExecutionService#should_process_captain_response?`
  lo consulta y, si aplica, **no encola** el job y emite un log estructurado
  (`[CAPTAIN][skip] reason=service_contact`). El mensaje queda visible en el inbox;
  simplemente el bot no participa.
- El mismo predicado excluye esas conversaciones del cron
  `InboxPendingConversationsResolutionJob`.
- Defensa en profundidad (config externa, documentada como complemento, no sustituto):
  desactivar en Evolution el reenvío de eventos de instancia a Chatwoot.
- Specs: contacto de servicio ignorado, cliente real respondido, número configurable,
  cron excluido.
- Estado real (2026-08-26): implementada, sintaxis y rubocop verificados. **No
  ejecutada contra BD** — bloqueador de entorno (WSL2/Hyper-V deshabilitado en esta
  máquina, ajeno al código). Ejecutar antes de mergear:
  `spec/models/contact_spec.rb`, `spec/models/conversation_spec.rb`,
  `spec/enterprise/models/captain_inbox_spec.rb`,
  `spec/enterprise/services/enterprise/message_templates/hook_execution_service_spec.rb`,
  `spec/enterprise/jobs/captain/inbox_pending_conversations_resolution_job_spec.rb`.

### Fase 1b — Contexto sano: lo que el LLM ve (PR pequeño, alto impacto en calidad) ✅ implementada

Ataca Q1 y Q2, que son los dos defectos que más degradan las respuestas reales:

- **Ventana de historial**: `collect_previous_messages` (compartido por V1 y V2 — el
  job pasa el resultado a ambos) se limita a los últimos N mensajes
  (`Captain::Assistant::DEFAULT_HISTORY_WINDOW_MESSAGES = 30`, configurable por
  assistant vía `config['history_window_messages']`). El sistema prompt no pasa por
  esta ventana (se arma aparte). La constante `MAX_MESSAGE_LENGTH` (antes código
  muerto) ahora trunca de verdad el contenido de cada mensaje individual, dentro de la
  ventana, para que un solo mensaje enorme no reviente el contexto.
- **Separación de voces**: `determine_role` ya no mapea todo `outgoing` a
  `'assistant'` — solo lo hace cuando `sender_type == 'Captain::Assistant'`
  (`bot_authored?`). Un mensaje `outgoing` de un agente humano entra con rol `'user'`
  y el contenido prefijado con `HUMAN_AGENT_MESSAGE_PREFIX` ("[Mensaje de un agente
  humano, no del asistente]: "). Se descartó marcarlo con rol `'system'`: el
  `chat_helper.rb` de este repo fusiona TODOS los mensajes de rol `system` en un solo
  bloque de instrucciones antes de la conversación, lo que habría destruido el orden
  cronológico. El prefijo aplica solo a la parte de texto en contenido multimodal
  (imágenes intactas). Esto corta la fuga de mensajes privados del operador hacia el
  proveedor LLM (evidencia real de producción: mensajes de prueba del admin —
  contraseñas, listas internas — se enviaban al LLM como si el propio asistente los
  hubiera dicho).
- Specs en `spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb`
  (nuevo bloque `'conversation history for the LLM'`): ventana respetada y en orden
  cronológico, agente humano nunca como `assistant`, respuesta previa del bot sí como
  `assistant`, truncado de mensaje largo. Verificado a mano que no rompe los specs
  existentes del archivo (mensajes cortos/incoming quedan bit-a-bit iguales; el test
  que fija `MAX_MESSAGE_LENGTH == 10_000` sigue pasando sin tocarlo).
- Igual que Fase 1: no ejecutada contra BD por el mismo bloqueador de entorno.
- **Refactor de ingeniería no planeado, aparecido al implementar**: mover la lógica al
  job (como estaba escrito inicialmente) empujaba `response_builder_job.rb` a 211
  líneas de cuerpo de clase, por encima del límite de `Metrics/ClassLength` (175). En
  vez de silenciar el linter, se extrajo toda la lógica de construcción de historial
  (ventana, truncado, atribución de rol, prefijo de agente humano) a una clase nueva,
  cohesiva y cero acoplada al job:
  [`Captain::Conversation::HistoryBuilder`](enterprise/app/services/captain/conversation/history_builder.rb).
  El job queda en su responsabilidad original (orquestar el flujo de respuesta/handoff)
  y delega con una sola línea:
  `Captain::Conversation::HistoryBuilder.new(conversation:, assistant:).call`. La
  extracción también resuelve limpio el hecho de que la lógica ya era compartida por
  V1 y V2 (un solo punto de construcción de historial, no dos). Spec dedicado y
  exhaustivo en
  [`spec/enterprise/services/captain/conversation/history_builder_spec.rb`](spec/enterprise/services/captain/conversation/history_builder_spec.rb);
  el spec del job quedó con una sola prueba de integración confirmando que delega
  correctamente, evitando duplicar cobertura entre los dos archivos.

### Fase 2 — Taxonomía de fallos y salud de credenciales (el PR central)

**2a. Clasificación de errores — ✅ implementada (2026-08-26).**

[`Captain::FailurePolicy`](enterprise/lib/captain/failure_policy.rb), único punto de
clasificación:

| Clase | Ejemplos | Política |
|-------|----------|----------|
| `configuration` | `RubyLLM::UnauthorizedError`, `ConfigurationError`, `PaymentRequiredError`, `ForbiddenError`; Gemini 400 con `API_KEY_INVALID` en el body (¡llega como `BadRequestError`, no 401!); OpenAI 429 `insufficient_quota` (¡llega como `RateLimitError`, igual que un rate-limit normal!) | Handoff al cliente + nota privada con la causa real |
| `transient` | `RateLimitError`, `ServerError`, `ServiceUnavailableError`, `OverloadedError`, `Faraday::TimeoutError`, `Faraday::ConnectionFailed`, `Timeout::Error` | **Sin handoff** — se re-lanza como `Captain::FailurePolicy::TransientProviderError` para que `retry_on` (job-level, backoff polinómico, 3 intentos) reintente. Nunca llega al cliente |
| `budget` | `RubyLLM::ContextLengthExceededError` | Handoff normal (reintentar con el mismo contexto fallaría igual) — sin nota especial, no es problema de credencial |
| `limit_adaki` | `Adaki::CaptainUsageTracker::LimitExceeded` | Handoff + nota privada |
| `unknown` | cualquier otro `StandardError` | Handoff normal, comportamiento previo sin cambios |

Wiring, cubriendo **ambos runtimes** (V1 lanza excepciones reales; V2 las traga
internamente y las devuelve como parte del hash de respuesta — ver
`AgentRunnerService#llm_error_response`/`#error_response`, ahora con
`'failure_class' => Captain::FailurePolicy.classify(error).to_s` añadido a ambas):

- `response_builder_job.rb#handle_error` (V1): clasifica, y si es `transient`
  re-lanza como `TransientProviderError` (capturado por `retry_on` a nivel de job)
  en vez de tratarlo como "error genérico → handoff".
- `response_builder_job.rb#generate_response_with_v2`: mismo re-lanzamiento, pero
  leyendo `@response['failure_class']` (el runner V2 nunca deja escapar la
  excepción original).
- **Refactor de ingeniería, mismo patrón que en Fase 1b**: la nota de diagnóstico se
  extrajo a [`Captain::Conversation::FailureNotifier`](enterprise/app/services/captain/conversation/failure_notifier.rb)
  (no vive en el job) — mismo motivo que `HistoryBuilder`: mantener el job en su
  responsabilidad de orquestación y no violar `Metrics/ClassLength`/complejidad por
  acumulación. La complejidad de `handle_error` también se redujo extrayendo
  `populate_error_diagnostics` (las 4 asignaciones `||=` no eran decisiones reales,
  solo contaban como ramas para el linter).
- Specs: `spec/enterprise/lib/captain/failure_policy_spec.rb` (unitario puro, sin
  BD — cubre las trampas Gemini/OpenAI con cuerpos de respuesta simulados),
  `spec/enterprise/services/captain/conversation/failure_notifier_spec.rb`,
  ampliaciones en `response_builder_job_spec.rb` y `agent_runner_service_spec.rb`
  (3 asserts `eq({...})` preexistentes actualizados para las claves nuevas —
  aditivas, no rompen `render json: response` del playground). Igual que fases
  previas: no ejecutado contra BD (bloqueador WSL2/Hyper-V), verificado con
  `ruby -c` + rubocop limpio + relectura manual de anidado de specs.
- `ConversationCompletionService` (política equivalente para el cron de
  auto-resolución, error ≠ `complete: false`) — **pendiente**, no incluido en esta
  pasada.

**2b. Circuit breaker de credencial — ✅ implementada (2026-08-26).**

[`Captain::CredentialCircuitBreaker`](enterprise/lib/captain/credential_circuit_breaker.rb),
keyed por cuenta (no por credencial — una cuenta puede usar credencial explícita o el
fallback global de `InstallationConfig`, y en cualquier caso es su tráfico el que hay
que frenar). Tras 3 fallos `configuration` en 10 min (estado en Redis vía
`Redis::Alfred`, TTL nativo — sin máquina de estados half-open explícita, el propio
vencimiento del TTL permite el siguiente intento), el circuito se abre: notifica una
vez (no en cada fallo posterior) vía `ChatwootExceptionTracker`, y mientras esté
abierto `response_builder_job#handle_open_circuit` hace handoff directo **sin llamar
al LLM** — nada de reintentos ni notas repetidas por cada mensaje entrante. Cualquier
respuesta exitosa (no solo una recuperación) cierra el circuito
(`track_credential_health!`, evita que fallos esporádicos no relacionados acumulen
hacia el umbral). Auto-sanador por diseño: no depende de que exista un job de
revalidación (ver 2c) — el propio TTL ya deja pasar el siguiente intento normalmente,
igual que el paso half-open clásico.
- Wiring: `record_failure!` se llama tanto desde `generate_response_with_v2` (lee
  `@response['failure_class']`) como desde `handle_error` (V1, vía
  `Captain::FailurePolicy.configuration?(error)`) — cubre ambos runtimes.
- Specs: `spec/enterprise/lib/captain/credential_circuit_breaker_spec.rb` (Redis
  real, sin mocks — `after { close!(account) }` evita fuga entre specs, ya que
  Redis no se limpia solo entre ejemplos en esta suite), ampliación de
  `response_builder_job_spec.rb` (circuito abierto salta el LLM; se abre tras el
  umbral en llamadas repetidas de integración).
- `.rubocop.yml`: `response_builder_job.rb` entró al Exclude de `Metrics/ClassLength`
  (justificado en el propio YAML) — ya tenía 3 colaboradores extraídos esta sesión
  (`HistoryBuilder`, `FailureNotifier`, `FailurePolicy`); lo que queda es
  orquestación genuina, no deuda sin atender.

**2c. Ciclo de vida de credenciales.**
- **Config viva — ✅ implementada (2026-08-26).** [`Llm::Config#initialize!`](../../lib/llm/config.rb)
  ahora hace `strip` de toda key leída de `InstallationConfig` (una key pegada con
  espacio/salto de línea fallaba autenticación sin pista alguna en el error del
  proveedor), y calcula un fingerprint (SHA-256) de los valores resueltos en cada
  llamada — `RubyLLM.configure`/`Agents.configure` (las operaciones caras, mutan
  estado global) solo se re-ejecutan si el fingerprint cambió desde la última vez.
  Rotar una key en el panel de Super Admin ya no exige reiniciar contenedores: el
  siguiente `initialize!` (se llama antes de cada operación LLM/Captain) detecta el
  cambio y reconfigura. `config/initializers/ai_agents.rb` pasó de configurar el SDK
  de agents por su cuenta (una sola vez, al boot) a delegar en
  `Llm::Config.initialize!`, así ambos SDKs (RubyLLM y ai-agents) quedan
  sincronizados siempre, no solo al arrancar.
  - **Diseño deliberadamente sin caché de TTL** (la idea original, 30 s) — antes de
    escribir código se detectó que cachear `provider_values` por tiempo de reloj
    filtraría un valor de un ejemplo de RSpec hacia otro dentro de la misma ventana:
    el rollback transaccional de Rails resetea la BD entre ejemplos, pero no un ivar
    de módulo Ruby, y `spec/rails_helper.rb` no tiene ningún hook que limpie este
    tipo de estado. La solución final evita el problema de raíz en vez de parchearlo:
    `provider_values` sigue leyendo la BD fresca en **cada** llamada (igual costo que
    antes, cero riesgo de fuga); lo único memoizado es el fingerprint (comparación
    barata), y como se deriva de una lectura siempre fresca, un test posterior que no
    toque `InstallationConfig` genera un fingerprint distinto al de un test anterior
    que sí lo hizo — detecta el "cambio" y reconfigura solo, sin necesitar un
    `before(:each)` global nuevo.
  - Specs: `spec/lib/llm/config_spec.rb` — nuevo bloque `.initialize!` (strip,
    dual-SDK, skip-si-no-cambió, reconfigura-si-cambió, `reset!` fuerza
    reconfiguración) y `.initialized?`; `around` que restaura
    `@configured_fingerprint` al valor previo al terminar cada ejemplo, para que el
    primer `initialize!` de un archivo de specs posterior siga viendo un fingerprint
    "distinto" y de verdad reconfigure en vez de heredar el no-op de este archivo.
  - `.rubocop.yml`: `Metrics/ModuleLength` de `lib/llm/config.rb` ya estaba en
    103/100 antes de esta sesión (confirmado con `git show HEAD | rubocop --stdin`);
    subió a 126/100 con esto — Exclude añadido con la misma justificación que los
    de `ClassLength`.
- **Job diario `Platform::Credentials::RevalidationJob`, ✅ implementado
  (2026-08-28).** Reutiliza `Platform::CredentialManager.validate!` (ya existía,
  ya actualiza `status`/`metadata['validation']` correctamente por proveedor —
  no hizo falta nueva lógica de validación, solo el job que la dispare a diario).
  Re-valida `active` e `invalid_credential` (una key rotada puede volver a
  funcionar); deliberadamente **no** toca `revoked` — eso lo apagó un humano a
  propósito, un job automático no debe reactivarlo solo porque la key volvió a
  responder. [`app/jobs/platform/credentials/revalidation_job.rb`](app/jobs/platform/credentials/revalidation_job.rb),
  agendado en `config/schedule.yml` a las 03:30 UTC, mismo patrón que
  `Adaki::AuditChainVerifyJob` (rescata por credencial, seguí con las demás si
  una falla, levanta un resumen al final para que Sidekiq lo marque como
  fallo/reintentable). Elimina O3. Spec:
  `spec/jobs/platform/credentials/revalidation_job_spec.rb`.
- **Fin de la herencia implícita, ✅ implementado (2026-08-28), default
  preserva el comportamiento actual.** `Llm::Config.global_fallback_allowed?`
  lee `InstallationConfig CAPTAIN_ALLOW_GLOBAL_FALLBACK` — **default `true`
  cuando la fila no existe** (a propósito: publicar este cambio no le apaga
  Captain a nadie hoy). El operador lo pone en `false` explícitamente
  (Super Admin, ya expuesto en `config/installation_config.yml`) una vez que
  confirme que cada cuenta que necesita Captain tiene su propia credencial.
  Con el flag en `false`, `ResponseBuilderJob#usable_credential_configured?`
  consulta `Platform::Models::Resolver` (la misma resolución que ya usan V1 y
  V2) antes de intentar cualquier llamada LLM — sin credencial resoluble, hace
  handoff limpio con nota de diagnóstico ("esta cuenta no tiene proveedor de
  IA configurado") en vez de heredar en silencio la key compartida
  (elimina O2/O4 como clase de fallo, una vez que el operador active el modo
  estricto). Mismo patrón de pre-flight que
  `Captain::CredentialCircuitBreaker.open?` — no toca `Llm::BaseAiService`
  (compartido por otras features de IA fuera de Captain, fuera de alcance
  aquí). Specs: `spec/lib/llm/config_spec.rb` (`.global_fallback_allowed?`) y
  `response_builder_job_spec.rb` (describe `'global credential fallback'` —
  default no cambia nada, flag off + sin credencial hace handoff, flag off +
  con credencial corre normal).
  - **Por qué el default no es "off" como decía el plan original**: al
    verificar contra producción (2026-08-28, `feature_enabled?` por cuenta vía
    `rails runner`) las 4 cuentas del operador (Adaki, Lazkao, Puntua mi
    Negocio, Silnatur) ya están en `captain_integration_v2=true`, y no se
    verificó el estado de credencial explícita por cuenta antes de decidir el
    default. Publicar con `false` por defecto habría podido apagar Captain en
    cuentas reales sin que el operador lo supiera de antemano. El mecanismo
    completo ya existe y funciona — flipear el switch es una decisión de un
    minuto del operador cuando confirme que cada cuenta tiene credencial
    propia, no un cambio de código.

### Fase 3 — Presupuestos de ejecución (PR corto) — ✅ implementada (2026-08-26)

> Detalles y correcciones de esta fase en `captain-referencias-tecnicas.md` §6
> (basado en el código fuente real de las gemas).

**Corrección a la investigación previa, antes de implementar: `max_turns` SÍ acota
el loop completo.** El hallazgo original (`captain-referencias-tecnicas.md` §6.1)
decía que `max_turns` solo cuenta handoffs entre agentes, no el loop de
tools/llamadas LLM. Releyendo el código fuente instalado
(`ai-agents-0.10.0/lib/agents/runner.rb#run`) antes de tocar nada: `current_turn`
se incrementa en **cada** iteración del loop principal — incluidas las
continuaciones por tool-call (`next if response.tool_call?`) y los handoffs — y
`raise MaxTurnsExceeded if current_turn > max_turns` corta ese mismo contador. Es
decir, ya es un presupuesto real de llamadas LLM/tool, no solo de handoffs. No hace
falta el contador manual vía `on_chat_created`/`on_end_message` que proponía el
plan original — habría sido complejidad redundante sobre algo que la gema ya hace.
Tampoco se encontró la fuga en inglés de `MaxTurnsExceeded`: cuando se dispara,
`result.error` queda seteado (la excepción), así que `process_agent_result` la
intercepta primero y usa `llm_error_response` — el texto en inglés de
`result.output` nunca se lee. (La fuga real de C12, vía el contenido crudo de un
`RubyLLM::Tool::Halt` no-handoff, es un problema *distinto*, sigue pendiente en
Fase 4.)

- **`max_turns` del runner V2: 100 → 10** (constante `MAX_TURNS`, coincide con el
  default/recomendación de la propia gema — antes era 10x eso, sin justificación en
  el código). Ambos call sites (`generate_response` y el reintento de
  `retry_if_promise_only`) usan la misma constante.
  [`agent_runner_service.rb`](enterprise/app/services/captain/assistant/agent_runner_service.rb),
  spec actualizado (`agent_runner_service_spec.rb`, referencias a `100` cambiadas a
  `described_class::MAX_TURNS`).
- **`RubyLLM.configure`: `request_timeout` 60 s, `max_retries` 1, `retry_interval` 1
  s** (defaults eran 300 s / 3 / 0.1 s — un proveedor lento podía ocupar un worker
  de Sidekiq varios minutos solo en reintentos de Faraday; el reintento con backoff
  ya vive en el job vía `retry_on Captain::FailurePolicy::TransientProviderError`,
  ver Fase 2a — una sola capa reintenta).
  [`lib/llm/config.rb`](lib/llm/config.rb) (`configure_ruby_llm`).
- **Cola dedicada `captain`** vía capsule de Sidekiq (soportado nativo desde
  Sidekiq 7, instalado 7.3.1 — no requiere Enterprise) para
  `Captain::Conversation::ResponseBuilderJob` y `Captain::Copilot::ResponseJob`: un
  incidente del proveedor deja de comerse la cola `default`.
  [`config/initializers/sidekiq.rb`](config/initializers/sidekiq.rb). **Ojo con el
  pool de conexiones**: `config/database.yml` dimensiona el pool de Postgres del
  proceso Sidekiq solo a partir de `SIDEKIQ_CONCURRENCY` — sumar hilos de una nueva
  capsule *por encima* de eso agotaría el pool bajo carga (cambiar un cuelgue por
  otro). La concurrencia de la capsule `captain`
  (`SIDEKIQ_CAPTAIN_CONCURRENCY`, default 3) se **resta** de la del capsule por
  defecto en vez de sumarse — el total de hilos no cambia, así que el pool
  existente sigue siendo correcto sin tocar `database.yml`.
  Specs: `described_class.queue_name` en ambos job specs.
- **`AuditLogger`: `pg_advisory_xact_lock` bloqueante → `pg_try_advisory_xact_lock`
  con reintento acotado** (5 intentos, 50 ms entre cada uno — ~200 ms peor caso en
  vez de espera indefinida). Bajo contención (o un holder de lock atascado), la
  versión bloqueante podía dejar un worker de Sidekiq colgado indefinidamente —
  esto importa porque `Adaki::CaptainUsageTracker#record!` llama a `AuditLogger.log`
  en **cada** respuesta V1 de Captain, no es un camino raro. Si los 5 intentos
  fallan, se levanta `Adaki::AuditLogger::LockContention` (antes: bloqueo eterno).
  [`app/services/adaki/audit_logger.rb`](app/services/adaki/audit_logger.rb) — se
  descartó la alternativa de sacar la cadena de hash a un job aparte: `.log` se
  llama desde 8+ sitios síncronos (controllers incluidos), y solo el de
  `captain_usage_tracker.rb` está en el hot path de Captain; mover TODOS a async
  rompería la expectativa de "la entrada existe al volver la llamada" en los demás
  sin necesidad. Specs nuevos (`lock contention`): agota los intentos → levanta
  `LockContention`; libera dentro del presupuesto → tiene éxito.
- **`Adaki::CaptainUsage.current_for`: `find_or_create_by!` → `create_or_find_by!`**
  (upsert atómico nativo de Rails, apoyado en el índice único real
  `[account_id, period]` de la migración — no hacía falta escribir
  `INSERT ... ON CONFLICT` a mano). Bajo dos respuestas de Captain concurrentes para
  la misma cuenta, `find_or_create_by!` puede perder la carrera entre el `find` y el
  `create` y levantar `RecordNotUnique`; `create_or_find_by!` intenta crear primero
  y se recupera reconsultando si choca con el índice único.
  [`app/models/adaki/captain_usage.rb`](app/models/adaki/captain_usage.rb). Spec
  nuevo `spec/models/adaki/captain_usage_spec.rb` — la carrera real no es
  reproducible de forma fiable contra una conexión envuelta en la transacción de
  fixtures de RSpec, así que se reprodujo de forma determinista: se stubea
  `create!` para levantar `RecordNotUnique` (simulando que otro proceso ganó la
  carrera) y se confirma que `current_for` se recupera en vez de propagar la
  excepción.

### Fase 4 — Un solo runtime (PR de consolidación) — parcial (2026-08-26)

**"V2 como único camino soportado, V1 congelado" NO se implementó esta pasada** —
deliberado: es exactamente la misma clase de decisión que quedó pendiente en Fase 2c
(cambia comportamiento por defecto de cuentas existentes, incluidas las del propio
operador que hoy dependen de V1). Sí se implementaron dos arreglos concretos que
NO dependen de esa decisión — ambos defectos catalogados en §1.2 desde el inicio de
la investigación, ambos re-verificados con evidencia directa (no solo releídos)
antes de tocar código:

**C5 — Tools V1 incompatibles, ✅ arreglado.** Verificación adicional antes de
implementar: `ruby -e` real confirmó que `Foo.new.execute(**{a:1})` contra un método
`execute(tool_context, **params)` sí produce
`ArgumentError: wrong number of arguments (given 0, expected 1)` — y `RubyLLM::Tool#call`
(gema instalada) llama exactamente `execute(**normalized_args)`, sin argumento
posicional. Todo tool built-in (`FaqLookupTool`, `HandoffTool`, cualquier
`add_label_to_conversation`/etc. — todos heredan de `Captain::Tools::BasePublicTool`
→ `Agents::Tool`) y todo `Captain::Tools::McpTool` crashea en cuanto el LLM intenta
llamarlo desde V1. Además: `Concerns::Toolable#tool` (usado por
`RegistryService#custom_tool_instances`) construye tools custom con
`base_class: Captain::Tools::HttpTool` por defecto — el bridge
`Captain::Tools::CustomHttpTool` (diseñado exactamente para este problema, según su
propio comentario) **nunca se conecta en ningún call site real** — así que las tools
custom HTTP tampoco funcionaban en V1. Esto coincide con la queja original del
usuario ("Captain se pega y siempre manda al agente") de forma más directa que la
key muerta encontrada al inicio: **cualquier V1 conversation que llegue a necesitar
FAQ lookup, labels, o una tool custom/MCP terminaba en handoff forzado por
`ArgumentError`**, no por decisión del asistente.
- Fix: [`assistant_chat_service.rb#build_tools`](enterprise/app/services/captain/llm/assistant_chat_service.rb)
  filtra `is_a?(Agents::Tool)` antes de pasar tools a `RubyLLM::Chat` — convierte el
  crash en "la tool simplemente no se ofrece", no en pérdida de capacidad real (V1
  nunca pudo usarlas). `custom_tools_metadata` (lo que el system prompt le dice al
  LLM que tiene disponible) también se vació — antes anunciaba tools MCP/custom que
  ya no estaban en el schema real de function-calling, invitando una alucinación
  "voy a usar X" sin tool real detrás.
  - **No se implementó el bridge genérico** (adaptar `McpTool`/custom tools a V1 en
    vez de excluirlas): revisando `McpTool`, no define `description`/`parameters` —
    hereda los defaults de `RubyLLM::Tool`, que probablemente tampoco están completos
    para exponer un schema útil al LLM. Construir ese bridge bien exige verificar
    contra un entorno real (bloqueado por WSL2/Hyper-V), así que se optó por la
    opción seria y ya documentada en el plan original: excluir, no adaptar a medias.
    Si se quiere recuperar MCP/custom tools en V1 más adelante, empezar por ahí.
  - Specs: `spec/enterprise/services/captain/llm/assistant_chat_service_spec.rb`,
    nuevo describe `'tool compatibility with V1'` — verifica que ningún
    `Agents::Tool` llega a `chat.with_tool`, y específicamente que
    `FaqLookupTool`/`HandoffTool` quedan fuera.

**C10 — Contabilidad Adaki, ✅ arreglado (solo tracking, no enforcement en V2).**
Verificación antes de implementar: `Captain::ChatResponseHelper#build_response`
devuelve el hash JSON ya parseado (`parsed`), no el `RubyLLM::Message` — confirmado
leyendo el código, `adaki_extract_token_counts` nunca tuvo datos reales de uso para
leer en V1. Y `Captain::Assistant::AgentRunnerService` no incluye `ChatHelper` en
ningún punto — confirmado que V2 nunca llamó a `Adaki::CaptainUsageTracker`. La
hipótesis original de "cuenta por round de tool-call" no se confirmó: solo hay 2
call sites de `request_chat_completion` en todo el repo, sin recursión — el conteo
de *solicitudes* (`request_count`) siempre fue correcto; el problema real era los
*tokens* (siempre 0 en V1, inexistentes en V2).
- Fix, mismo patrón en ambos runtimes — acumular vía `on_end_message` (fuente real
  de tokens por llamada LLM, confirmado ya usado para Langfuse en
  `chat_generation_recorder.rb`), sumar a través de **todas** las llamadas LLM que
  hizo una sola respuesta (una respuesta con tool-calls dispara `on_end_message`
  varias veces), registrar una sola vez al final:
  - V1: [`chat_helper.rb`](enterprise/app/helpers/captain/chat_helper.rb) añade
    `accumulate_llm_usage`/`llm_usage` (acumulador de instancia, junto al
    `record_llm_generation` existente en el mismo hook);
    [`chat_helper_adaki.rb`](enterprise/app/helpers/captain/chat_helper_adaki.rb)
    lee `llm_usage` tras `super` en vez de introspeccionar `response`.
  - V2: [`agent_runner_service.rb`](enterprise/app/services/captain/assistant/agent_runner_service.rb)
    añade `add_usage_tracking_callback` — `runner.on_chat_created` (dispara por
    cada `RubyLLM::Chat` que crea el runner, incluido tras un handoff) registra
    `chat.on_end_message` para acumular en `context_wrapper.context[:captain_v2_usage]`;
    `record_adaki_usage!` lee el total del `result.context` final y llama a
    `Adaki::CaptainUsageTracker.record!` — nuevo, antes no existía ninguna llamada.
  - **Deliberadamente solo tracking, no enforcement, en V2**: `enforce_limit!` no se
    conectó al runner V2. Conectarlo empezaría a bloquear cuentas que hoy están
    silenciosamente sin límite en V2 — mismo tipo de decisión que "fin de herencia
    implícita" en Fase 2c, necesita que el operador la tome explícitamente, no que
    sea un efecto secundario de arreglar la contabilidad.
  - Specs: `assistant_chat_service_spec.rb` (describe `'Adaki usage tracking'` — token
    counts reales, suma a través de múltiples llamadas), `agent_runner_service_spec.rb`
    (describe `'#add_usage_tracking_callback'` y `'#record_adaki_usage!'`, siguiendo
    el patrón ya establecido en el archivo de invocar el método privado directo con
    dobles simples en vez de simular el flujo completo). **Importante**: hubo que
    añadir `allow(mock_runner).to receive(:on_chat_created)` al `before` global del
    spec — sin eso, TODOS los tests existentes del archivo habrían roto contra el
    `instance_double(Agents::AgentRunner)` en cuanto `runner` se construyera, porque
    `add_usage_tracking_callback` ahora llama a ese método incondicionalmente.

**C6 — señal de handoff única, ✅ neutralizado como efecto colateral de C5, sin
tocar código.** Re-evaluado tras el fix de C5: el riesgo que describía C6 ("un
`bot_handoff!` ejecutado por tool en V1 pasaría desapercibido y el job postearía
encima") ya no puede ocurrir — V1 no puede llamar `HandoffTool` en absoluto desde
que `v1_compatible_tools` la excluye. El único runtime que sí puede invocar la tool
(V2) ya trackea `handoff_tool_called` de forma confiable, con fallback a
`@handoff_tool_called` para el camino de error donde el context es inalcanzable
(`agent_runner_service.rb#track_handoff_usage`). No se encontró una fuga concreta
adicional que justifique tocar un mecanismo que ya funciona — refactorizar solo por
"tres formas de decir lo mismo" sin un bug real detrás no se hizo.

**C12 — filtro de salida para el leak de anuncio de transferencia falso, ✅
implementado (2026-08-27, opción "suprimir + loguear").** Caso concreto (conv 120,
observado en producción): el LLM (V2) responde "Se ha transferido la conversación al
agente de información de productos" **sin haber llamado la tool de handoff** —
alucina la acción, el cliente cree que viene un humano, no viene nadie.

Investigación previa a implementar (el operador pidió explícitamente ver si esto le
pasa a otros con Chatwoot y cómo lo resuelve la industria, antes de decidir):
industria general lo llama *fabricated tool call* / *tool-call hallucination* — caso
casi idéntico documentado en agentes de voz de Retell AI (el agente anuncia "te
transfiero" y la tool nunca se dispara). El patrón de mitigación estándar
(paper *Tool Receipts, Not Zero-Knowledge Proofs*) es verificación por "recibo": si
el texto afirma una acción y no existe el registro real de que ocurrió, se trata
como no verificada. En Chatwoot específicamente: issue
[#13881](https://github.com/chatwoot/chatwoot/issues/13881) (bug opuesto —
handoff real sin mensaje) se arregló con PR
[#13885](https://github.com/chatwoot/chatwoot/pull/13885) exponiendo el flag
`handoff_tool_called` como fuente de verdad — **el mismo mecanismo que ya usa este
fork** (confirma que C6, dejado sin tocar, ya está alineado con el fix oficial
upstream). No se encontró un issue público de Chatwoot sobre el caso específico de
C12 (anuncio falso, no mensaje faltante) — parece no reportado todavía upstream.

Diseño (usa exactamente el "recibo" que ya existe, `handoff_tool_called`, como
fuente de verdad — no inventa mecanismo nuevo):
- [`agent_runner_service.rb#suppress_handoff_announcement_leak!`](enterprise/app/services/captain/assistant/agent_runner_service.rb):
  si `handoff_tool_called` es `false` y la respuesta matchea
  `HANDOFF_ANNOUNCEMENT_LEAK_PATTERN` (ES/EN), se reemplaza por un fallback neutro
  (`conversations.captain.handoff_announcement_leak_fallback`, nueva clave en
  `en.yml`/`es.yml` — NO reutiliza `captain.handoff` porque ese texto también
  afirma una transferencia que no ocurrió) y se loguea con `Rails.logger.warn`
  (visibilidad — permite medir qué tan seguido pasa esto antes de decidir si algún
  día vale la pena la opción 2, forzar handoff real).
  Un mensaje de handoff **legítimo** (tool sí llamada) nunca pasa por este código:
  ya usa el template limpio de `create_handoff_message` en `process_v2_handoff`, y
  el guard `return if response['handoff_tool_called']` lo confirma explícitamente
  aunque el texto contenga las mismas palabras.
- Solo V2 — V1 no puede llegar a este escenario específico (nunca tuvo la tool
  disponible ni antes ni después del fix de C5, así que no puede "fingir" haberla
  usado tampoco).
- Specs: dos contextos nuevos en `agent_runner_service_spec.rb` — respuesta que
  miente sobre un handoff (se suprime + loguea) vs. respuesta que menciona
  transferencia CON la tool realmente llamada (no se toca, pasa intacta).

**Sin tocar esta pasada**: la política "V2 único / V1 congelado" (Fase 4) sigue
fuera de alcance por la misma razón que el resto de la herencia implícita en Fase
2c — cambia comportamiento por defecto de cuentas existentes.

### Fase 5 — Verificación y observabilidad (cierra la meta-causa) — CI parcial ✅

- **CI para `spec/enterprise/`**: nuevo
  [`.github/workflows/run_ee_spec.yml`](.github/workflows/run_ee_spec.yml). Mismo
  patrón que `run_foss_spec.yml` (Postgres pgvector + Redis como servicios, matriz de
  8 nodos, `schema:load`) pero **sin** el paso "Strip enterprise code", y acotado a
  `find spec/enterprise -name '*_spec.rb'` (correr de nuevo el resto del suite FOSS
  aquí no aporta señal nueva — ya lo cubre el otro workflow). Verificado: sintaxis
  YAML válida y diff estructural contra `run_foss_spec.yml` sin desvíos accidentales
  (revisado a mano, línea por línea).
  - **Con `continue-on-error: true`, deliberado y temporal — pero el bloqueo real
    ya cayó.** Los "42 fallos preexistentes" de `captain-limits.md` eran un número
    viejo, nunca remedido. Con WSL2/Hyper-V resuelto (2026-08-28), corrí
    `spec/enterprise` completo (216 archivos) contra Postgres/Redis reales por
    primera vez: **1900 examples, 5 failures** — y **ninguna de las 5 tiene nada
    que ver con Captain, Adaki, ni con ningún archivo tocado en esta sesión**:
    1. `spec/enterprise/mailers/devise_mailer_spec.rb:52` — el HTML del email de
       invitación SSO cambió de contenido, el test compara el string viejo.
    2. `spec/enterprise/models/account_saml_settings_spec.rb:60` — espera
       `sp_entity_id` con host `localhost:3000`, esta máquina resuelve
       `0.0.0.0:3000` — diferencia de configuración de entorno, no un bug de
       código.
    3–5. `spec/enterprise/models/inbox_spec.rb:142,174,218` — esperan 1 entrada de
       `Audited::Audit` (la gema `audited`, **no** `Adaki::AuditLogEntry`) al crear
       un inbox, la BD real tiene 2 — deuda genuina, pero en un sistema de
       auditoría completamente distinto al que tocó esta sesión.
    Con esto: la deuda preexistente real es **5 fallos, todos ajenos a Captain**,
    no 42. Graduar el gate no se hizo en esta pasada (sigue siendo una decisión de
    triage — `skip`/`xit` con fecha para los 5, o arreglarlos aparte — que no es
    parte del alcance de "arreglar Captain"), pero el riesgo que justificaba
    mantenerlo en `continue-on-error` ("no sé si son 42 o más") ya no existe.
  - **Para graduarlo a gate real** (quitar la línea `continue-on-error`): marcar
    los 5 fallos de arriba con `skip`/`xit` + comentario y fecha (o arreglarlos,
    son triviales — 2 son de configuración/contenido, no de lógica), y borrar la
    línea.
  - Hallazgo colateral al diseñar esto, fuera del alcance de esta fase pero anotado:
    `run_foss_spec.yml` borra `enterprise/` **antes** de correr los specs FOSS, pero
    en producción (este fork fuerza modo enterprise siempre) varias clases FOSS
    reciben `prepend` de módulos enterprise (`Enterprise::MessageTemplates::
    HookExecutionService` sobre `MessageTemplates::HookExecutionService`,
    `Captain::ChatHelperAdaki` sobre `Captain::ChatHelper`, etc.). El CI FOSS nunca
    ejercita ese comportamiento parcheado — testea una configuración hipotética que
    no es la que corre en real. Corregir esto (correr TODO el suite con enterprise/
    cargado) es un cambio de alcance mucho mayor — duplica cómputo de CI y puede
    destapar regresiones ocultas en specs que hoy pasan solo porque el parche no
    está — no se aborda aquí.
- **Toda decisión de no-responder emite una razón**: `service_contact`, `quota`,
  `human_takeover`, `no_credential`, `circuit_open`, `audience_mismatch`,
  `group_no_mention`, `error:<clase>` — un solo formato de log
  (`[CAPTAIN][decision] account=X conv=Y action=skip|reply|handoff reason=Z`).
  El diagnóstico que hoy costó horas de grep pasa a ser una consulta.
- Alerta simple: >N handoffs con `reason=error:*` en 15 min → notificación admin.

---

## 5. Estado del árbol de trabajo

Todo sin commitear (2026-08-26), en el working tree, listo para revisar/commitear
por partes. Fases 0-1b y el arranque de Fase 5 ya implementadas con specs:

- **Fase 1** (contrato de ingesta): `app/models/contact.rb`, `app/models/
  conversation.rb`, `enterprise/app/models/captain_inbox.rb`,
  `enterprise/app/services/enterprise/message_templates/hook_execution_service.rb`,
  `enterprise/app/jobs/captain/inbox_pending_conversations_resolution_job.rb`,
  `.rubocop.yml` (exclusión de `ClassLength` para `contact.rb`, mismo patrón que
  `message.rb`/`conversation.rb`) + 5 specs (2 nuevos, 3 ampliados).
- **Fase 1b** (contexto sano): `enterprise/app/models/captain/assistant.rb`
  (config `history_window_messages`), `enterprise/app/jobs/captain/conversation/
  response_builder_job.rb` (reducido, delega en la clase nueva), clase nueva
  `enterprise/app/services/captain/conversation/history_builder.rb` + spec dedicado
  nuevo + 1 spec de integración en el job existente.
- **Fase 5, arranque** (CI): `.github/workflows/run_ee_spec.yml` (nuevo, en
  `continue-on-error` hasta que alguien lo corra una vez con Docker real).
- **Fase 2a** (clasificación de fallos): `enterprise/lib/captain/failure_policy.rb`
  (nuevo), `enterprise/app/services/captain/assistant/agent_runner_service.rb`,
  `enterprise/app/services/captain/conversation/failure_notifier.rb` (nuevo),
  `enterprise/app/jobs/captain/conversation/response_builder_job.rb`, `.rubocop.yml`
  (exclusión `ClassLength` para `agent_runner_service.rb`, deuda preexistente) + 4
  specs (2 nuevos, 2 ampliados).
- **Fase 2b** (circuit breaker de credencial):
  `enterprise/lib/captain/credential_circuit_breaker.rb` (nuevo),
  `enterprise/app/jobs/captain/conversation/response_builder_job.rb`, `.rubocop.yml`
  (exclusión `ClassLength` para `response_builder_job.rb`, justificada — 3
  colaboradores ya extraídos) + spec nuevo + ampliación del job.
- **Fase 4, parcial** (C5 + C10):
  `enterprise/app/services/captain/llm/assistant_chat_service.rb` (filtro
  `Agents::Tool` para V1), `enterprise/app/helpers/captain/chat_helper.rb` +
  `chat_helper_adaki.rb` (acumulador de tokens reales V1),
  `enterprise/app/services/captain/assistant/agent_runner_service.rb` (tracking de
  uso Adaki en V2, antes inexistente), `.rubocop.yml` (exclusión `ModuleLength` para
  `chat_helper.rb`, ya era deuda preexistente) + specs nuevos en
  `assistant_chat_service_spec.rb` y `agent_runner_service_spec.rb`.
- **Fase 2c completa**: `lib/llm/config.rb` (fingerprint + strip + dual-SDK +
  `global_fallback_allowed?`), `config/initializers/ai_agents.rb` (ahora delega en
  `Llm::Config.initialize!`), `config/installation_config.yml` (nueva entrada
  `CAPTAIN_ALLOW_GLOBAL_FALLBACK`), `enterprise/app/jobs/captain/conversation/
  response_builder_job.rb` (`usable_credential_configured?`/`handle_missing_credential`,
  extraído `dispatch_response` para no exceder `Metrics/MethodLength`),
  `app/jobs/platform/credentials/revalidation_job.rb` (nuevo),
  `config/schedule.yml` (cron diario 03:30 UTC), `.rubocop.yml` (exclusión
  `ModuleLength` para `config.rb`, ya era deuda preexistente) + specs nuevos/
  ampliados en `spec/lib/llm/config_spec.rb`,
  `spec/jobs/platform/credentials/revalidation_job_spec.rb` (nuevo),
  `response_builder_job_spec.rb`.
- **Fase 3** (presupuestos de ejecución):
  `enterprise/app/services/captain/assistant/agent_runner_service.rb` (`MAX_TURNS`
  10, era 100), `lib/llm/config.rb` (timeouts/reintentos de RubyLLM),
  `config/initializers/sidekiq.rb` (capsule `captain`),
  `enterprise/app/jobs/captain/conversation/response_builder_job.rb` +
  `enterprise/app/jobs/captain/copilot/response_job.rb` (`queue_as :captain`),
  `app/services/adaki/audit_logger.rb` (lock no bloqueante),
  `app/models/adaki/captain_usage.rb` (upsert atómico) + specs nuevos/ampliados en
  `agent_runner_service_spec.rb`, `audit_logger_spec.rb`,
  `spec/models/adaki/captain_usage_spec.rb` (nuevo), ambos job specs de Captain.
- Documentación: este archivo, `captain-referencias-tecnicas.md`,
  `captain-diagnostico-handoff.sql`.

**✅ Verificado contra BD/Redis real por primera vez esta sesión (2026-08-28).**
Desbloqueado WSL2/Hyper-V a mitad de sesión (Docker Desktop volvió a arrancar);
contenedores `chatwoot-adaki-test-pg`/`chatwoot-adaki-test-redis` (memoria
`local-test-db-setup`) levantados, Redis limpiado con `FLUSHALL`, schema
confirmado al día (`db:migrate:status`, sin migraciones pendientes). Resultado
final: **450 examples, 0 failures**.

La primera corrida (antes de arreglar nada) dio **15 fallas reales**, todas
defectos genuinos introducidos esta misma sesión — ni un solo falso positivo del
entorno. Exactamente la clase de riesgo que motivaba correr esto antes de dar por
cerrado el trabajo:

- **`Captain::Conversation::HistoryBuilder` — orden de mensajes roto (el más
  serio).** `Message` tiene `default_scope { order(created_at: :asc) }`; un
  `.order(created_at: :desc)` encadenado se **agrega** a ese order en vez de
  reemplazarlo, así que el SQL final quedaba `ORDER BY created_at ASC, created_at
  DESC, ...` — el `ASC` de la default_scope ganaba siempre. Con `LIMIT` de por
  medio, esto podía devolver los mensajes **más viejos** en vez de los más
  recientes, o mezclar el orden cronológico que el `.reverse` posterior asume.
  Arreglado con `.reorder(created_at: :desc, id: :desc)` (`reorder` sí reemplaza;
  `id` como desempate porque `created_at` solo no es una clave de orden estable
  entre mensajes creados muy seguido). El código original (antes de la ventana de
  Fase 1b) no tenía este bug — no llevaba `LIMIT` ni orden explícito, solo
  heredaba el `ASC` de la default_scope sin conflicto.
- **`Adaki::CaptainUsage.current_for` — el fix de C9 (Fase 3) empeoraba el caso
  normal.** `create_or_find_by!` intenta `create!` primero, lo que dispara la
  validación `validates :account_id, uniqueness: { scope: :period }` **antes**
  de llegar a la capa de BD — y esa validación falla con
  `ActiveRecord::RecordInvalid` (no `RecordNotUnique`), que
  `create_or_find_by!` no rescata. Como `current_for` se llama en
  prácticamente cada respuesta de Captain, esto rompía el caso **común**
  (la fila del mes ya existe), no solo la carrera rara. Arreglado quitando la
  validación de unicidad — el índice único real de la migración ya la
  reemplaza, y es justo el patrón que la documentación de Rails recomienda al
  usar `create_or_find_by!`.
- **`Captain::ChatHelperAdaki` nunca se activaba en test.** Su
  `Captain::ChatHelper.prepend(Captain::ChatHelperAdaki)` vive como efecto de
  borde al fondo del archivo — Zeitwerk solo lo autocarga si algo referencia la
  constante. `RAILS_ENV=test` tiene `eager_load = false`
  (`config/environments/test.rb`), así que nada lo cargaba nunca; en producción
  (`eager_load = true`) sí carga al bootear. Confirmado con
  `Captain::ChatHelper.ancestors` en `rails runner` real. No es un bug de
  producción, pero sí una fragilidad real (depender de eager_load para activar
  un monkey-patch) — la contabilidad Adaki de V1 era, hasta ahora, código sin
  ninguna cobertura real posible en specs. Arreglado en el spec (referenciar la
  constante fuerza el autoload); la fragilidad de fondo queda documentada, no
  rediseñada.
- **2 tests con expectativas equivocadas** (no bugs de producción): uno asumía
  que `RubyLLM.configure` se llama una sola vez por `Llm::Config.initialize!`
  sin contar que `Agents.configure` (ai-agents gem) también lo llama
  internamente; otro creaba un mensaje humano saliente que disparaba
  legítimamente `Captain::HumanTakeoverEvaluator` (comportamiento correcto)
  en vez de aislar lo que el test realmente quería probar (el wiring de
  `HistoryBuilder`).
- **Contaminación propia durante el diagnóstico**: un script de `rails runner`
  usado para depurar el bug de `HistoryBuilder` dejó una cuenta/conversación
  reales comiteadas en la BD de test (fuera de la transacción de RSpec,
  invisible al rollback). Rompió 12 tests de `sort_on_*` no relacionados
  (`Conversation.sort_on_created_at` etc. no filtran por cuenta). Limpiado con
  otro `rails runner` puntual; no queda residuo.

Comando para reproducir:

```bash
POSTGRES_HOST=localhost POSTGRES_PORT=55432 REDIS_URL=redis://localhost:56379 \
  bundle exec rspec spec/models/contact_spec.rb spec/models/conversation_spec.rb \
  spec/enterprise/models/captain_inbox_spec.rb \
  spec/enterprise/services/enterprise/message_templates/hook_execution_service_spec.rb \
  spec/enterprise/jobs/captain/inbox_pending_conversations_resolution_job_spec.rb \
  spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb \
  spec/enterprise/services/captain/conversation/history_builder_spec.rb \
  spec/enterprise/lib/captain/failure_policy_spec.rb \
  spec/enterprise/services/captain/conversation/failure_notifier_spec.rb \
  spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb \
  spec/enterprise/lib/captain/credential_circuit_breaker_spec.rb \
  spec/lib/llm/config_spec.rb \
  spec/services/adaki/audit_logger_spec.rb \
  spec/services/adaki/captain_usage_tracker_spec.rb \
  spec/models/adaki/captain_usage_spec.rb \
  spec/enterprise/jobs/captain/copilot/response_job_spec.rb \
  spec/enterprise/services/captain/llm/assistant_chat_service_spec.rb \
  spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb \
  spec/jobs/platform/credentials/revalidation_job_spec.rb
# 450 examples, 0 failures (última corrida limpia: 2026-08-28)
```

## 6. Orden y esfuerzo estimado

| Fase | Riesgo | Esfuerzo | Valor | Estado |
|------|--------|----------|-------|--------|
| 0 | nulo (config) | 30 min | Adaki responde hoy; inventario veraz; temperatura/citas sanas | pendiente (manual, tuya) |
| 1 | bajo | 0,5-1 día | Corta el 90% del gasto y los handoffs falsos | ✅ implementada |
| 1b | bajo | 0,5-1 día | Respuestas sin contaminar; fin de la fuga de mensajes del operador al LLM | ✅ implementada |
| 5 (CI) | bajo | 0,5-1 día | Todo lo anterior queda protegido | ✅ arrancada + baseline remedido (1900 examples, 5 fallos reales — ninguno de Captain; workflow sigue en `continue-on-error`, ver §Fase 5) |
| 2a | medio | 1 día | El sistema deja de mentir sobre sus fallos (clasificación) | ✅ implementada |
| 2b | medio | 1 día | Circuit breaker por credencial | ✅ implementada |
| 2c | medio | 1 día | Config viva, revalidación diaria, fin de herencia global | ✅ implementada (fin de herencia con default que preserva el comportamiento actual — el operador activa el modo estricto cuando confirme credenciales por cuenta) |
| 3 | bajo | 0,5-1 día | Fin de los cuelgues de minutos y del lock | ✅ implementada |
| 4 | medio | 2-3 días | Deja de existir el doble camino V1/V2 | parcial — C5, C6 (neutralizado por C5), C10 y C12 resueltos; solo queda la política "V2 único / V1 congelado" (decisión del operador) |

Orden recomendado: 0 → 1 → 1b → 5 → 2a → 2b → 2c → 3 → 4 (seguido en esta sesión).
Ninguna fase se ha ejecutado contra una BD real — bloqueador de entorno (WSL2/
Hyper-V deshabilitado en esta máquina), no del código; ver checklist de specs a
correr antes de mergear en §5 más arriba.

## 7. Incidente 2026-09-04 — "pedí un agente y no me mandó con nadie" (conv 120, cuenta 3)

Reproducido con logs de Rails + Sidekiq y BD de producción. El cliente escribió
"Quisiera hablar con un agente"; el bot contestó "Te transfiero con un agente
humano…" y la conversación siguió `open`, sin assignee ni equipo, y el bot
habría vuelto a responder al siguiente mensaje. Cinco fallos encadenados, todos
con fix en el mismo commit:

| # | Fallo | Evidencia | Fix |
|---|-------|-----------|-----|
| H1 | El turno arrancó en el agente de escenario 34 ("Información sobre Productos"), que **no tiene la tool `handoff`** (solo las que referencia su instrucción: `faq_lookup`, `add_label`). Su única "transferencia" es `handoff_to_<asistente>` (volver al orquestador IA) — y eso llamó. | Log: `tool_calls: handoff_to_asistente_puntua_mi_negocio`; BD: `captain_scenarios.tools` del 34 | `Captain::Scenario#agent_tools` añade siempre `HandoffTool`; `scenario.liquid` explica que `handoff_to_<asistente>` no es un humano |
| H2 | Tras el hand-back, el orquestador (Gemini) leyó el texto de la tool de la gema ("I'll transfer you to … who can better assist you") y **narró** la transferencia sin llamar `handoff` | `handoff_tool_called=false` en el resultado | `assistant.liquid`: ese resultado es interno y ya terminó; si el usuario pidió humano, llamar `handoff` ahora |
| H3 | El filtro anti-fuga (C12) solo cubría `transferid[oa]`; "Te transfiero" pasó al cliente | `HANDOFF_ANNOUNCEMENT_LEAK_PATTERN` | Patrón ampliado a formas verbales en primera persona / futuro / enclíticas, con tabla de casos positivos y negativos en el spec |
| H4 | Aunque `handoff` hubiera disparado, la conversación **ya estaba `open`**: `bot_handoff!` → `open!` sin cambio de estado → `AutoAssignmentHandler` no corre, nadie asignado, y `HumanTakeoverEvaluator` no sabe que el bot se apartó → el bot vuelve al siguiente mensaje. En el modo Adaki "bot responde en open" el handoff era invisible | BD: `status=0, assignee_id=NULL, team_id=NULL`, `enable_auto_assignment=t` | `Enterprise::Conversation#bot_handoff!` estampa `additional_attributes.captain_handoff_at` y dispara la auto-asignación del inbox también cuando ya estaba open; `HumanTakeoverEvaluator#captain_handoff_pending?` silencia al bot hasta que un humano responda o la conversación se resuelva (una reapertura posterior empieza de cero) |
| H5 | **Escenario pegajoso sin caducidad**: la gema retoma el sub-agente del último mensaje etiquetado, sin noción de tiempo. Desde 2026-06-11 todos los mensajes del bot en la conv 120 llevaban `agent_name=scenario_34…`, incluidas las respuestas a "Hola" y a la petición de humano | BD: `messages.additional_attributes.agent_name` | `HistoryBuilder::AGENT_STICKINESS_WINDOW = 1.hour`: la etiqueta caduca; tras ese silencio el turno vuelve al orquestador, que re-enruta si sigue siendo relevante |

Efecto colateral deliberado de H4: un handoff provocado por un fallo de
infraestructura (credencial muerta) también silencia al bot en esa conversación
hasta que un humano responda. El circuit breaker (2b) sigue protegiendo a nivel
de cuenta (spec ajustado: una conversación nueva por fallo).

Decisión pendiente del operador: la asignación tras handoff usa la
auto-asignación del inbox (round robin de miembros online, o `AssignmentJob` con
`assignment_v2`). Si se prefiere asignar siempre al equipo `soporte` (team 1),
es un `team_id` en `run_handoff_auto_assignment`.

### 7.1 Seguimiento (misma fecha): equipo de handoff configurable y nota con @mención

- **Equipo de handoff** (`handoff_team_id`): configurable en el asistente y
  sobreescribible por bandeja (`captain_inboxes.settings`; `0` explícito =
  sin equipo). `Enterprise::Conversation#bot_handoff!` etiqueta la
  conversación con ese equipo si no tenía ninguno y la auto-asignación se
  limita a sus miembros. Sin equipo: auto-asignación entre todos los miembros
  del inbox (comportamiento anterior).
- **Nota de fallo con @mención**: `FailureNotifier` corre ahora *después* de
  `bot_handoff!` y menciona al asignado (o al equipo de handoff si la
  asignación aún no ocurrió — con `assignment_v2` es un job asíncrono). La
  mención genera notificación `conversation_mention` con el texto del error
  (cuota agotada, credencial muerta). Formato: markup de Chatwoot
  `[@Nombre](mention://user|team/ID/Nombre)`, procesado por
  `Messages::MentionService`.
- **Deploy**: Coolify solo hace `pull` de `ghcr.io/...:latest`; si se
  despliega antes de que GitHub Actions termine la imagen (~4 min), se
  redespliega la imagen anterior con el commit nuevo en la etiqueta. El
  workflow `build-coolify-image.yml` tiene un paso que avisa a Coolify al
  terminar, pero requiere los secrets `COOLIFY_WEBHOOK_URL` y `COOLIFY_TOKEN`
  en GitHub (no configurados a 2026-09-04).

### 7.2 Respuesta vacía de Gemini y nivel de razonamiento configurable

Conversación 309 (2026-09-04 02:41), mensaje "Que productos tiene ?": el runner
V2 terminó con `output=""` y `output_tokens=0`, sin error y sin tool call.
`ResponseBuilderJob#validate_message_content!` lanzó `ArgumentError` →
`handle_error` → handoff. El cliente pidió información de productos y acabó
transferido a un humano.

**Causa.** Gemini 2.5 razona antes de responder; esas partes vienen marcadas
`thought: true`, RubyLLM las descarta (`extract_content` filtra los thought
parts) y los tokens de razonamiento se cobran a precio de salida y cuentan
contra el límite de salida. Cuando el razonamiento se lleva el turno entero, la
respuesta llega sin texto visible. Ni RubyLLM ni ai-agents envían un
`thinkingConfig` por su cuenta — RubyLLM solo lo hace si alguien llama
`with_thinking`, y el runner de la gema nunca lo llama — así que Gemini venía
aplicando su presupuesto dinámico por defecto, sin techo.

**Dos capas de arreglo:**

1. **Red de seguridad** (`AgentRunnerService`): una respuesta vacía se reintenta
   una vez con `EMPTY_REPLY_NUDGE` (mismo mecanismo que el reintento por
   "promesa sin tool"); si sigue vacía, se envía
   `conversations.captain.empty_reply_fallback` en vez de una cadena vacía. Una
   respuesta vacía ya no puede convertirse en handoff. Un handoff real (con la
   tool llamada) no se toca.
2. **Causa raíz** (`Llm::Thinking` + ajuste por asistente): nuevo
   `config.reasoning_level` con tres valores — `off` (por defecto), `low`,
   `dynamic`. `Concerns::Agentable` lo traduce a los params del proveedor y los
   pasa a `Agents::Agent#params`; el runner los aplica con `chat.with_params` y
   RubyLLM los deep-mergea en el payload (`Provider#complete` →
   `Utils.deep_merge`), así que llegan como `generationConfig.thinkingConfig`
   sin parchear ninguna gema.

Detalles por modelo, verificados contra la documentación de Google:

| Modelo | `off` | `low` | Nota |
|---|---|---|---|
| gemini-2.5-flash / flash-lite | `thinkingBudget: 0` | `512` | 0 desactiva el razonamiento |
| gemini-2.5-pro | `thinkingBudget: 128` | `128` | Pro **no** permite 0; 128 es el suelo de la API |
| gemini-3-* | `thinkingLevel: "low"` | igual | La familia 3 usa nivel, no presupuesto, y no se puede desactivar |
| Otros proveedores | sin params | sin params | Sin equivalente cableado aquí |

`dynamic` no envía nada y deja decidir al proveedor: es el comportamiento
anterior, y el que provocó el incidente.

**Default `off` a propósito.** Captain consulta FAQs y enruta a escenarios; el
razonamiento interno solo añadía latencia, coste (unos 3,50 USD por millón de
tokens de salida con razonamiento frente a 0,60 sin él) y este modo de fallo.
Quien quiera lo contrario lo cambia desde Captain → Asistente → Ajustes del
sistema → "Nivel de razonamiento del modelo".

### 7.3 La marca de handoff caduca con la ventana de re-enganche

El fix de §7 (marca `captain_handoff_at`) silenciaba al bot **hasta que un
humano respondiera o la conversación se resolviera**, sin límite de tiempo. En
producción eso produjo el fallo contrario al original: conversación 309, a las
03:08:44 el cliente escribió "Hola" y el job de Captain **no se encoló** — la
conversación seguía marcada desde la transferencia falsa de las 02:41:58 y
nadie la había recogido, porque la auto-asignación no encontró candidatos (el
operador no era colaborador de la bandeja). Ni bot ni humano: silencio.

`Captain::HumanTakeoverEvaluator#captain_handoff_pending?` respeta ahora el
modo de re-enganche que ya estaba configurado, en vez de imponer un silencio
absoluto:

| Modo | Tras el handoff |
|---|---|
| `after_window` (default) | Silencio durante la ventana configurada (15 min por defecto); si nadie lo recoge, el bot sigue ayudando |
| `never` | Silencio permanente: el humano es dueño de la conversación |
| `always` | Sin silencio; el handoff igual asigna, etiqueta con el equipo y notifica |

Es la misma pregunta que ya respondía la ventana para las respuestas humanas
—cuánto esperamos a que un humano se haga cargo— así que no añade un ajuste
nuevo. La asignación, la etiqueta de equipo y la notificación del handoff
siguen ocurriendo igual en los tres modos.
