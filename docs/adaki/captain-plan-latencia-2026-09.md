# Captain: plan de latencia (septiembre 2026)

Fecha: 2026-09-16. Origen: quejas de "Captain tarda un minuto en responder".
Continúa `captain-latencia.md` (05-09).

Estado: fase 0 (medir) y fase 1 (cola) con código listo y specs en verde
localmente, sin desplegar (PR #40). Fase 2 (Evolution) investigada — ver §8.
Fase 3: 3.1 (timeout 30s), 3.2 (failover de modelo), 3.3 (umbral de
distancia en el prefetch), 3.5 (usage/audit después de responder) y 3.6
(caché del resolver) con código listo y specs en verde localmente, sin PR
aún. Falta 3.4 (prompt estable / `prompt_cache_key`). Fases 4-6 sin empezar.

## 1. Diagnóstico (datos de producción)

Medido en `postgres-prod`, mensaje del cliente guardado → respuesta de Captain guardada:

| Periodo | p50 | p90 | máx |
|---|---|---|---|
| junio–agosto | 1.4–2.1 s | 2.0–3.5 s | 29.6 s (1 caso) |
| semana 07-09 | 10.7 s | 13.7 s | 15.3 s |
| semana 14-09 | 8.6 s | 9.3 s | 10.0 s |

Ningún caso >30 s en 90 días. Lo que sí hay:

1. **Evolution reconecta 5–12 veces al día por número** (mensajes "Connection successfully
   established!" del contacto +123456, desde junio, 80–120/semana con 3 inboxes). Mientras
   Baileys está caído el mensaje no entra y la respuesta no sale. No se ve en la DB, el
   cliente lo vive como un minuto de espera. Reconexiones mayoritariamente independientes
   por instancia (27 de 129 coinciden con otra inbox en ±3 min): no es reinicio global.
2. **6 respuestas perdidas** con `Net::ReadTimeout` hacia el webhook de Evolution
   (04-09, 06-09). `Webhooks::Trigger` marca `failed` y no reintenta.
3. **Silnatur sin responder del 18-08 al 01-09** (28 de 28 mensajes). Corregido con los
   fixes del 03/04-09; desde el 07-09, 0 sin respuesta.
4. **Regresión interna de 2 s → 9 s** desde el deploy del 05-09: el debounce
   `set(wait: 2.seconds)` va al scheduled set de Sidekiq y espera al poller (intervalo
   aleatorio 2.5–7.5 s con un proceso). 2 s reales = 4.5–9.5 s. El requeue por lock
   (`wait: 5.seconds`) paga lo mismo: 7.5–12.5 s.
5. **Primer mensaje más lento en Puntua**: orquestador → `handoff_to_scenario_X` →
   segunda llamada LLM (12 455 tokens de entrada frente a 5 184 en el turno pegajoso).
   Tras 1 h sin actividad (`AGENT_STICKINESS_WINDOW`) vuelve a pagar las dos llamadas.
6. Silnatur (gpt-4.1-mini, ~2k tokens) tarda 10 s por turno; Puntua (gemini-2.5-flash,
   5–13k tokens, 16 escenarios) 3–4 s. El modelo no es el cuello; la cola sí.

Único camino interno a 60 s+: `request_timeout 60` × `max_retries 1` de RubyLLM
(`lib/llm/config.rb`) → una petición colgada son 60–120 s antes de fallar, y luego
`retry_on` añade 3 s y 18 s.

## 2. Gemas: qué hay y qué no

### ai-agents (instalada 0.10.0, última 0.12.0 del 29-06-2026)

| Versión | Qué trae | Nos sirve |
|---|---|---|
| 0.11.0 | `provider:` y `assume_model_exists:` en `Agents::Agent.new`; arreglo de atribución de agente en el historial multi-agente (#68) | Sí: permite retirar la parte `with_model` del parche `config/initializers/ruby_llm_thread_context.rb` (el contexto por hilo sigue haciendo falta). El fix #68 toca exactamente el `agent_name` que usa `HistoryBuilder`. |
| 0.12.0 | Metadatos Langfuse propagados a spans hijos, `generation_attributes`, temperatura en spans | Solo si activamos OTEL |

**No existe** en ninguna versión: tools por paso (`activeTools`/`prepareStep`), tools
diferidas, caché de prompt, streaming. El runner (`lib/agents/runner.rb`):
- crea **un** `RubyLLM::Chat` por run y lo reutiliza;
- fija las tools **una vez por agente** con `chat.with_tools(*tools, replace:)`; solo
  las reconfigura en un handoff (`replace: true`);
- el handoff **no crea chat nuevo**: cambia instrucciones, modelo y tools sobre el mismo
  objeto (el historial se conserva, el prefijo cacheado del proveedor se pierde);
- `on_chat_created` entrega el `chat`. Ya lo usamos en `add_usage_tracking_callback`.

Consecuencia: la "capa 3" de komunikia (ampliar tools por paso) se puede hacer **sin
cambiar de gema**: guardar el `chat` de `on_chat_created` y, desde `on_tool_complete`,
llamar `chat.with_tools(nueva_tool, replace: false)`; RubyLLM las incluye en la
siguiente petición. Es un hack sobre estado interno del runner: aceptable, pero solo si
la fase 4 lo necesita (ver abajo; con las capas 1 y 2 probablemente no).

`ai-agents` exige `ruby_llm ~> 1.14`: **no** es compatible con ruby_llm 2.0.

### ruby_llm (instalada 1.15.0, última estable 1.16.0 del 09-06-2026; 2.0.0.rc4 del 16-09)

1.16.0, sin breaking changes:
- "Gemini function call responses now adhere to spec" → candidato a retirar
  `config/initializers/ruby_llm_gemini_tool_call_ids.rb` (verificar con el spec del parche).
- Ejecución concurrente de tool calls (`config.tool_concurrency = true`).
- Eventos `ActiveSupport::Notifications` (`request.ruby_llm`, `tool_call.ruby_llm`):
  tiempo real por llamada al proveedor sin parchear nada.
- `ContextLengthExceededError` tipado.

2.0 (rc): `with_caching` unificado, model fallbacks, aprobaciones de tools, Responses API
por defecto en OpenAI. Rompe API y ai-agents no lo soporta. **No adoptar** hasta que
ai-agents publique compatibilidad.

Decisión: subir a **ai-agents 0.12.0 + ruby_llm 1.16.0** (fase 6). Nada de 2.0.

## 3. Plan por fases

Orden por impacto/riesgo. Cada fase es un PR propio (los specs solo corren en
`pull_request`). Desplegar solo cuando GitHub haya terminado la imagen.

### Fase 0 — Medir antes de tocar (½ día)

Sin esto el resto es fe.

- `Captain::Conversation::ResponseBuilderJob`: una línea por respuesta
  `[CAPTAIN][timing] conversation= queue_wait_ms= lock_ms= history_ms= prefetch_ms= llm_ms= tools_calls= agents= input_tokens= output_tokens= total_ms=`.
  `queue_wait` = `Time.current - enqueued_at`. `llm_ms` medido alrededor de `runner.run`.
- `ENABLE_SIDEKIQ_DEQUEUE_LOGGER=true` en el servicio sidekiq de Coolify.
- Guardar la query SQL de `captain-latencia.md` como baseline; repetir tras cada fase.
- Criterio de éxito global: p50 Chatwoot < 4 s, p90 < 7 s, 0 mensajes sin respuesta.

### Fase 1 — Cola: recuperar los 5–7 s del poller (½ día)

- `Enterprise::MessageTemplates::HookExecutionService#schedule_captain_response`:
  encolar **sin** `wait:`. El debounce pasa dentro del job: al entrar,
  `sleep(CAPTAIN_RESPONSE_DEBOUNCE_SECONDS)` y después `superseded_by_newer_message?`.
  Con tráfico actual (decenas de mensajes/día) ocupar un hilo 2 s es gratis.
- `requeue_after_lock_contention`: en vez de `set(wait: 5.seconds)`, esperar en el job
  (bucle de `sleep 1` hasta 60 s sobre `Redis::LockManager#locked?`) y correr.
  Mantener el `MAX_LOCK_ATTEMPTS` como tope.
- Alternativa más simple si no se quiere bloquear hilos: `config[:average_scheduled_poll_interval] = 1`
  en `config/initializers/sidekiq.rb` (un ZRANGEBYSCORE por segundo, coste nulo).
- Atajo inmediato sin código: `CAPTAIN_RESPONSE_DEBOUNCE_SECONDS=0`.
- Esperado: p50 de 9 s a ~3–5 s en Silnatur; Puntua a ~2–3 s.

### Fase 2 — Evolution (ops, en paralelo con todo)

- Leer en Evolution los `connection.update` con `close` y su `reason`
  (428 connectionLost, 515 restartRequired, 440 conflict). Sin eso, cualquier fix es a ciegas.
- Comprobar que el fix "de hace unos días" hace bajar la query diaria de reconexiones
  (ver `captain-latencia.md`, contacto +123456). La semana del 14-09 seguía a 9–10/día.
- Una instancia por número, `CACHE_REDIS_ENABLED=true`, Chatwoot por hostname interno.
- `WEBHOOK_TIMEOUT` (GlobalConfig) a 10 s: 5 s es corto cuando Evolution está reconectando.
- `Webhooks::Trigger`: reintentar el webhook de api inbox en `Net::ReadTimeout`/
  `ConnectionFailed` (3 intentos, backoff) antes de marcar el mensaje `failed`. Hoy la
  respuesta se pierde en silencio.
- Alerta: más de 5 "Connection successfully established" por número y día → aviso.

### Fase 3 — La llamada al LLM (2–3 días)

1. **Presupuesto**: `request_timeout` 60 → 30 s en `lib/llm/config.rb`. Ninguna respuesta
   real pasa de 15 s.
2. **Failover de modelo** (patrón `komunikia lib/ai/resilience/failover-middleware.ts`):
   cuando `Captain::FailurePolicy` clasifica un error como transitorio o de configuración
   del proveedor, `AgentRunnerService` repite el turno **una vez** con el siguiente modelo
   habilitado de la cuenta (`Platform::Models::Resolver` ya devuelve varios: Silnatur tiene
   gpt-4.1-mini y gpt-5.4-mini; Puntua dos Gemini). Solo si es de otro proveedor o modelo.
   Registrar `[CAPTAIN][failover] from= to=`.
3. **Prefetch con umbral**: `Captain::KnowledgePrefetcher` inyecta siempre las 5 FAQs más
   cercanas. Añadir gate por distancia coseno (`nearest_neighbors` expone `neighbor_distance`;
   umbral inicial 0.65 de distancia = 0.35 de similitud, configurable por env) y lista de
   acuses de una palabra. Menos tokens y menos ruido en "hola", "gracias", "vale".
4. **Prompt estable de verdad**: `prompts/assistant.liquid` y `scenario.liquid` renderizan
   `conversation` (estado, prioridad, etiquetas, atributos) y `contact` en el **system**.
   Cambian entre turnos y rompen el prefijo cacheado. Moverlos al bloque del mensaje de
   usuario junto a `<knowledge_base_results>` (misma técnica que ya usa el prefetcher) o
   dejar en el system solo lo inmutable (ids). Con OpenAI, añadir `prompt_cache_key =
   "captain:<assistant_id>"` vía `params` del agente (`Agents::Agent params:` →
   `with_params`, disponible desde 0.10).
5. **Trabajo pesado después de responder**: `record_adaki_usage!` (2 transacciones +
   advisory lock de la cadena de auditoría) corre en `AgentRunnerService#generate_response`
   antes de que el job cree el mensaje. Moverlo a después de `create_messages` en el job,
   o a un job aparte. Ídem `Captain::CredentialCircuitBreaker` (Redis) si mide algo.
6. **Caché de resolución**: `Platform::Models::Resolver` carga credenciales y ~170 filas de
   `platform_credential_models` por turno; `Llm::Config.initialize!` lee 10
   `InstallationConfig` por llamada. Cachear el resultado del resolver por cuenta en Redis
   (TTL 5 min, invalidar al editar credenciales/modelos). Milisegundos, pero gratis.

### Fase 4 — Escenarios sin segunda llamada (3–5 días, solo cuentas con escenarios)

Hoy: orquestador (llamada 1) → `handoff_to_scenario_N` → escenario (llamada 2) → después
pegajoso 1 h. Objetivo: 1 llamada en la mayoría de turnos y sin pegajosidad ciega.

1. **Pre-enrutado determinista** (equivalente al picker `/skill` de komunikia, pero
   automático): embedding del último mensaje (ya lo calcula el prefetcher, cacheado)
   contra embeddings de `title + description` de los escenarios (columna nueva
   `captain_scenarios.embedding`, se rellena al guardar). Si el mejor supera el umbral,
   el turno arranca **directamente en el agente del escenario** (`runner.run` acepta el
   agente inicial vía `context[:current_agent]`, que es como el runner retoma un escenario
   pegajoso hoy). Sin llamada al orquestador.
2. **`load_scenario` como herramienta** (capa 2 de komunikia): para lo que el pre-enrutado
   no capte, el orquestador llama `load_scenario(key)` y recibe las instrucciones como
   resultado de tool; sigue el mismo agente, mismo system prompt, prefijo cacheado. Sigue
   siendo una segunda llamada, pero más barata que un handoff. Los 16
   `handoff_to_*` se sustituyen por 1 tool + 16 líneas de manifiesto en el prompt.
   Mantener `handoff_to_*` solo para escenarios con tools propias distintas.
3. **Pegajosidad**: con pre-enrutado por turno, `AGENT_STICKINESS_WINDOW` deja de ser
   la única señal. Bajarla a 15 min y dejar que el enrutado decida.
4. **Tools diferidas** (capa 3): opcional. Las 5 tools de housekeeping (`add_label…`,
   `update_priority`, `add_private_note`, `add_contact_note`, `resolve_conversation`)
   son ~600 tokens por llamada. Si tras medir compensa: tool `more_tools(query)` +
   `chat.with_tools(..., replace: false)` desde `on_tool_complete` con el `chat` capturado
   en `on_chat_created`. Documentar como parche sobre el runner.

Esperado: Puntua primer turno de 7–10 s a 3–4 s; tokens por respuesta a la mitad.

### Fase 5 — Calidad y robustez (2 días)

- **Modelo utilitario por rol**: resolver un modelo "barato" por cuenta (nuevo `feature`
  en `Platform::Models::Resolver`, p. ej. `utility`) para clasificadores V1, generación de
  FAQs, notas de contacto y jueces. Hoy todo va al modelo del asistente.
- **Juez de dos capas para promesas vacías** (`komunikia lib/chat/announce-guard.ts`):
  las regex `PROMISE_ONLY_PATTERNS` solo descartan; un `generateObject` con el modelo
  utilitario decide si repetir el turno. Menos repeticiones espurias y menos falsos negativos.
- **Resumen en vez de truncar**: cuando la conversación supera la ventana
  (`history_window_messages`), un job resume los turnos viejos con el modelo utilitario y
  lo guarda en `conversation.additional_attributes['captain_summary']`; `HistoryBuilder`
  lo inyecta como bloque volátil. Mantiene contexto en hilos largos de WhatsApp y el
  prefijo de los mensajes recientes.
- **Reintento de entrega**: ya en fase 2.

### Fase 6 — Gemas (1 día + verificación)

- `Gemfile`: `ai-agents '>= 0.12.0'`, `ruby_llm '>= 1.16.0'`. Ejecutar la suite de
  `spec/enterprise` en PR.
- Verificar con los specs de `config/initializers/ruby_llm_gemini_tool_call_ids.rb` si el
  parche sobra en 1.16; si sí, retirarlo.
- Pasar `provider:` y `assume_model_exists: true` a `Agents::Agent.new` en
  `Concerns::Agentable#agent` (0.11) y reducir `ruby_llm_thread_context.rb` a solo el
  contexto por hilo.
- Suscribirse a `request.ruby_llm` para alimentar la línea de timing de la fase 0 con el
  tiempo real de cada petición al proveedor.
- `config.tool_concurrency = true`: sin efecto hoy (una tool por turno), gratis para el futuro.

## 4. Orden y expectativa

| Orden | Fase | Esfuerzo | Ahorro esperado por respuesta | Riesgo |
|---|---|---|---|---|
| 1 | 0 Medir | ½ d | 0 (visibilidad) | nulo |
| 2 | 1 Cola | ½ d | 4–7 s | bajo |
| 3 | 2 Evolution | ops | el "minuto" del cliente | fuera de Chatwoot |
| 4 | 3.1–3.3 timeout, failover, prefetch | 1 d | fiabilidad + 0.3–0.5 s | bajo |
| 5 | 3.4–3.6 prompt estable, usage después, caché | 1–2 d | 0.5–1 s (caché de prefijo) | medio (specs de prompt) |
| 6 | 4 Escenarios | 3–5 d | 3–5 s en el primer turno de Puntua | medio |
| 7 | 5 Calidad | 2 d | menos repeticiones y handoffs falsos | bajo |
| 8 | 6 Gemas | 1 d | instrumentación; retirar parches | medio (regresión de proveedor) |

Meta: de p50 9–11 s a 2–4 s dentro de Chatwoot; el resto depende de Evolution.

## 5. Lo que no se toca

- No streaming: WhatsApp entrega el mensaje entero.
- No `ruby_llm` 2.0 hasta que ai-agents lo soporte.
- No subir `SIDEKIQ_CAPTAIN_CONCURRENCY`: la cola `captain` no acumula con el tráfico actual.
- No bajar `history_window_messages` por debajo de 16: la ventana no es el problema.

## 6. Referencias

- Datos: `captain-latencia.md` (query de medición), memoria `captain-latency-sources`.
- Patrones portados: komunikia-v4 `lib/chat/orchestrator.ts` (métricas), `system-blocks.ts`
  (estable/volátil), `rag/forced.ts` (umbral), `lib/ai/resilience/failover-middleware.ts`,
  `announce-guard.ts`, `compact.ts`, `lib/ai/tools/tools.ts` + `prepare-step.ts` (tools diferidas).
- Gemas: rubygems.org/gems/ai-agents (0.12.0), github.com/chatwoot/ai-agents CHANGELOG,
  rubygems.org/gems/ruby_llm (1.16.0, 2.0.0.rc4), github.com/crmne/ruby_llm/releases.

## 7. Qué hace la industria con ai-agents (investigación 16-09)

### La comunidad de la gema

Ecosistema pequeño: 1 issue abierta (#21 streaming, desde jul-2025), 65 PRs cerrados, sin
guía de rendimiento en la documentación (ai-agents.chatwoot.dev). Nadie publica
optimizaciones de latencia sobre esta gema. Lo que sí hay en el repo y sirve:

- **`Agent#as_tool`** (docs/concepts/agent-tool.md): el sub-agente recibe solo el
  estado compartido, no el historial, máximo 3 turnos, sin handoffs. La propia doc avisa
  del "overhead of multiple agent calls" y de no anidar agentes. Para Captain: cada
  escenario como tool costaría igual o más que el handoff (el sub-agente no ve la
  conversación), así que no sustituye al handoff para responder al cliente.
- **`AgentRunner#determine_conversation_agent`** (lib/agents/agent_runner.rb): el agente
  inicial es el `agent_name` del último mensaje assistant del historial, o el primero de
  la lista. No hay parámetro explícito. Consecuencia: el pre-enrutado de la fase 4 se
  implementa poniendo `agent_name = handoff_key del escenario` en el último mensaje
  assistant que `HistoryBuilder` entrega (o en uno sintético vacío). Cero cambios en la gema.
- **`HandoffTool`** (lib/agents/handoff.rb): nombre `handoff_to_<agente>`, descripción fija
  "Transfer conversation to <name>", sin parámetros. El modelo elige solo por la lista de
  escenarios del prompt. Su `halt` devuelve "I'll transfer you to X who can better assist
  you" — es el texto que `INTERNAL_AGENT_HANDOFF_PATTERN` ya filtra.
- **PR #60** (abierto): `handoff_description` en Agent/HandoffTool. **PR #75** (draft):
  handoffs con esquema propio y hooks `on_handoff`. Si se fusionan, el enrutado por
  handoff mejora; no cambian el coste de la segunda llamada.

### Chatwoot upstream (rama develop)

- **No hay debounce.** `Captain::Conversation::ResponseSchedulerService` encola al
  instante; solo espera 1–5 s si el mensaje trae adjuntos. Pasa `message.id` al job y
  este descarta la respuesta si llegó un mensaje más nuevo (`newer_customer_message_arrived?`)
  — mismo mecanismo que nuestro `superseded_by_newer_message?`, sin el coste del
  scheduled set. Confirma la fase 1.
- **Historial sin límite** (`MessageHistoryBuilderService`): nuestro `HistoryBuilder`
  con ventana está por delante.
- **Sin prefetch de FAQs, sin caché, sin failover.** `max_turns: 10`. Un módulo
  `ResponseLifecycleLogging` que registra solo saltos de estado, no tiempos.
- Los metadatos de conversación y contacto siguen en el system prompt, igual que aquí.

### Patrones de la industria (OpenAI Agents SDK, Anthropic)

- **OpenAI Agents SDK** (handoffs): `input_filters` para recortar el historial que hereda
  el agente destino (p. ej. `remove_all_tools`) y `nest_handoff_history` (beta) que
  compacta el historial en cada salto. Recomendación explícita: handoff para transferir
  la conversación, `as_tool` para consultas estructuradas sin transferir contexto.
  ai-agents no tiene input filters; nuestro `HistoryBuilder` ya hace el recorte antes
  del run, que es el equivalente barato.
- **Anthropic, "Building effective agents"**: patrón *Routing* — un clasificador barato
  decide la rama y cada rama tiene su prompt especializado; añadir agentes "solo cuando
  mejora resultados de forma demostrable". Es exactamente la fase 4.1 (enrutado por
  embeddings antes del orquestador).
- **Guías de latencia para SDKs de agentes** (Vex): comprimir el system prompt (ejemplo
  publicado: 2 450 → 780 tokens), modelo pequeño para agentes no críticos, cachear
  resultados de tools repetidas, alertar si un handoff pasa de 5 s o un run de 8k tokens.
  Aplicado a Captain: `assistant.liquid` son 6.7 KB + 16 escenarios; hay recorte posible.

### Qué cambia en el plan

- Fase 1 queda validada por upstream: encolar sin `wait:` y descartar por mensaje más nuevo.
- Fase 4.1 se concreta: pre-enrutado = `agent_name` en el historial, sin tocar la gema.
- Fase 4.2 (`load_scenario` como tool) sigue siendo nuestra; ni la gema ni upstream lo tienen.
- Añadir a la fase 3: compresión del prompt del orquestador (medir tokens del system con
  la línea de timing antes y después).

## 8. Fase 2 — Evolution: hallazgos (16-09, sin acceso a logs del contenedor)

`coolify-adaki-proyect` (MCP) no conectó en ninguna de las dos sesiones
(`CONNECTION_CLOSED`). Sin logs de Baileys no hay códigos `reason` (428/515/440/401)
por evento — lo de abajo sale enteramente de los mensajes de servicio (+123456) en
`postgres-prod`, cruzando con la memoria `evolution-service-contact-noise`
(`source_id` nulo, contacto +123456 = ruido de Evolution, no cliente real).

### El "fix de hace unos días" no bajó nada

Reconexiones diarias (`Connection successfully established`) por inbox, últimos 21 días:
sin tendencia a la baja. La semana del 14-09 sigue en 5-12/día por instancia, igual que la
semana del 07-09 citada en el plan original; el 15-09 fue el peor día medido (25 eventos
sumando las 3 inboxes) por el incidente de abajo. **El fix no tuvo efecto medible, o no
tocó la causa real.**

### Hallazgo nuevo: no son solo reconexiones — hay caídas de sesión completas

De los 260 eventos "Connection successfully established" en 21 días, la enorme mayoría
llega **sin** un `instance status: closed` previo en Chatwoot (solo 3 casos): son blips
cortos, Baileys reconecta solo, probablemente `428 connectionLost` de red — consistentes
con el "5-12/día, independientes por instancia" ya documentado.

Pero hay un patrón distinto y más grave, visto 2 veces en 21 días:

- **Puntua Mi Negocio, 15-09 14:19-14:54 (35 min)**: la instancia cae, y en vez de
  reconectar sola entra en un bucle de generación de QR — 62 "QRCode successfully
  generated!" en 27 minutos (uno cada ~45 s, el ciclo típico de refresco de QR de
  Baileys) hasta tocar `QRCode generation limit reached`. Se recupera recién tras un
  reintento manual ("send 'init' message again"), no solo. Ningún cliente real pudo
  escribir a esa inbox durante los 35 minutos.
- **Silnatur, 04-09 13:13-13:35 (22 min)**: mismo patrón — 14 QR + 5 con *Pairing Code*
  (el código alfanumérico de emparejamiento sin escanear, propio de un logout real, no
  de una reconexión) antes de "instance status: closed" y la recuperación. Coincide con
  la fecha de 2 de los 6 `Net::ReadTimeout` ya documentados en `captain-latencia.md`.

**Un bucle de QR/pairing code solo ocurre cuando Baileys pierde las credenciales de
sesión** (equivalente a `401 loggedOut`), no en una caída de red transitoria —
`515 restartRequired` o `428 connectionLost` reconectan con la sesión existente, sin
pedir escanear nada. Esto es el "minuto" (en realidad hasta 35 minutos) que reporta el
cliente: no es la cola de Chatwoot ni el LLM, es la instancia de WhatsApp completamente
caída y sin poder recibir mensajes.

**Causa probable**: algo fuerza un logout de sesión (no solo una desconexión) en
Silnatur y Puntua cada 1-2 semanas — puede ser el propio "fix" reciente, un reinicio del
contenedor que no persiste `session.json`/auth state a disco (o a Redis si
`CACHE_REDIS_ENABLED` no cubre las credenciales de sesión, solo la caché de
`createConversation`), o WhatsApp invalidando la sesión del lado del cliente
(multidispositivo, límite de dispositivos vinculados). No se puede diferenciar sin el
log de Evolution en el momento exacto (14:19 del 15-09 y 13:13 del 04-09).

### Qué falta (bloqueado sin acceso)

1. Log del contenedor `evolution` en Coolify en esas dos ventanas — el evento
   `connection.update` con `lastDisconnect.error.output.statusCode` justo antes del
   primer QR de cada incidente.
2. Confirmar si la sesión (`auth_info_baileys` o equivalente) persiste en volumen
   montado o en Redis, y si sobrevive a un redeploy/reinicio del contenedor.
3. Confirmar `CACHE_REDIS_ENABLED`, versión de Evolution/Baileys, una instancia por
   número, y si Chatwoot se llama por hostname interno (todo pendiente, ver plan
   original §3 fase 2).

### Acciones concretas (no bloqueadas por logs)

1. **Alerta ya**: un handler que cuente "QRCode successfully generated" por instancia
   en una ventana de 5 min y avise a partir de 3 — hoy este incidente es invisible hasta
   que un cliente se queja. Más barato y accionable que la alerta genérica de "más de 5
   reconexiones/día" del plan original.
2. **`WEBHOOK_TIMEOUT` a 10 s y reintento en `Webhooks::Trigger`** (ya en el plan,
   fase 2): durante los 22-35 minutos de bucle de QR, cualquier webhook de Chatwoot hacia
   Evolution falla con `Net::ReadTimeout` y hoy se pierde en silencio.
3. Pedir al usuario acceso a los logs de Coolify (UI o SSH) para el punto "Qué falta" —
   sin eso, fase 2 no puede ir más allá de la correlación hecha aquí.
