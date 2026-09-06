# Captain: latencia y formato en WhatsApp (Evolution)

Fecha: 2026-09-05. Síntoma reportado: "fuerte delay" entre el mensaje del cliente y la
respuesta de Captain por WhatsApp (Evolution API sobre `Channel::Api`), y respuestas con
`### encabezados` y `[url](url)` crudos en el móvil.

## Dónde se va el tiempo (ruta completa)

```
WhatsApp → Evolution → (3-4 llamadas API a Chatwoot; con caché de conversación, 1)
        → Chatwoot crea el mensaje → HookExecutionService encola ResponseBuilderJob
        → [debounce 2 s] → cola `captain` (3 hilos)
        → LLM #1 (orquestador) → [handoff a escenario → LLM #2] → [tool faq_lookup: embedding + pgvector → LLM #3]
        → mensaje saliente → WebhookJob (cola `medium`) → Evolution (+0,5–2 s aleatorios, hardcodeado)
        → WhatsApp
```

Cada llamada al LLM son segundos. El objetivo de todos los cambios es **menos llamadas al
LLM por respuesta** y **menos trabajo repetido por turno**.

## Cambios hechos (todos con specs)

| Cambio | Archivo | Efecto |
|---|---|---|
| FAQs pre-recuperadas en el prompt | `enterprise/lib/captain/knowledge_prefetcher.rb`, `prompts/snippets/knowledge.liquid` | La respuesta típica pasa de 2–3 llamadas LLM a 1: el modelo ya tiene los 5 FAQs más cercanos al último mensaje antes de empezar. `faq_lookup` sigue disponible para lo que el prefetch no cubra. Se salta mensajes de 1 palabra. |
| Tool duplicada eliminada del orquestador | `registry_service.rb`, `assistant.liquid` | `search_documentation` era la misma búsqueda que `faq_lookup`; el prompt pedía usar una y "verificar" con la otra. |
| Escenario ya no busca para "hola" | `scenario.liquid` | Antes: "ALWAYS search the FAQs". |
| Coalescer ráfagas de mensajes | `hook_execution_service.rb`, `response_builder_job.rb` | Debounce `CAPTAIN_RESPONSE_DEBOUNCE_SECONDS` (default 2). Si llega otro mensaje del cliente mientras espera, el job anterior se retira y el último responde a toda la ráfaga con una sola llamada LLM. Antes: N mensajes seguidos = N runs paralelos ocupando los 3 hilos y N respuestas. |
| Caché de embeddings de búsqueda | `embedding_service.rb` | Redis, 24 h, por modelo + texto normalizado. Solo `purpose: :search`. |
| Imágenes antiguas fuera del historial | `history_builder.rb` (`RECENT_IMAGE_MESSAGES = 4`) | Cada foto de la ventana de 30 mensajes se re-descargaba y re-enviaba en base64 en cada turno. |
| Registro de tools compartido por turno | `assistant.rb#cache_tool_registry`, `scenario.rb` | Antes 2 queries por cada tool de cada escenario. |
| Sesión MCP reutilizada | `mcp_tool.rb`, `call_service.rb` | Un handshake por turno, no por llamada. |
| Un solo run por conversación | `response_builder_job.rb` (`LOCK_TTL`, `Redis::LockManager`) | Dos jobs sobre la misma conversación ya no se solapan: el segundo se re-encola cada 5 s y responde justo después. Elimina respuestas duplicadas y desordenadas. |
| Prompt de sistema cacheable | `knowledge_prefetcher.rb#attach`, `agent_runner_service.rb` | Los FAQs pre-recuperados viajan en el mensaje del usuario, no en el system prompt. El prompt queda idéntico entre turnos → Gemini/OpenAI reutilizan el prefijo cacheado (input más barato y primer token más rápido). |
| Tope de tokens de salida | `lib/llm/output_limit.rb`, `agentable.rb` | 800 por defecto (`max_response_tokens` por asistente). En Gemini se suma el presupuesto de razonamiento para no truncar. Menos tokens generados = respuesta más rápida. |
| Ventana de historial por canal | `assistant.rb` (`DEFAULT_CHAT_HISTORY_WINDOW_MESSAGES = 16`) | En canales de chat 16 mensajes en vez de 30, salvo configuración explícita del admin. |
| Formato para WhatsApp | `chat_text_formatter.rb`, `prompts/snippets/formatting.liquid` | Encabezados → negrita, `[texto](url)` → url. `**` se deja: Evolution lo convierte a `*`. |

## Variables de entorno relevantes (servicio sidekiq en Coolify)

| Variable | Default | Cuándo tocarla |
|---|---|---|
| `CAPTAIN_RESPONSE_DEBOUNCE_SECONDS` | 2 | 0 para responder a cada mensaje al instante (vuelve el comportamiento anterior). |
| `SIDEKIQ_CAPTAIN_CONCURRENCY` | 3 | Subir a 5 si en `/monitoring/sidekiq` la cola `captain` acumula latencia en horas punta. Recuerda que se resta de `SIDEKIQ_CONCURRENCY` (10): súbela también. |
| `ENABLE_SIDEKIQ_DEQUEUE_LOGGER` | false | true para ver en logs cuánto espera cada job en cola. |

Ajustes por asistente (Captain → Asistente → Ajustes del sistema, campos de `config`):
`max_response_tokens` (default 800) y `history_window_messages` (default 30, o 16 en
canales de chat si no se fija).

## Recomendaciones fuera del código de Chatwoot

1. **Modelo del asistente: Gemini 2.5 Flash con razonamiento `off`** (Captain → Asistente →
   Ajustes del sistema). Pro tiene un suelo de `thinkingBudget: 128` y multiplica la latencia
   por 3–5 sin mejorar respuestas de FAQ. Comprobar qué modelo tiene cada asistente en
   producción: el log `[Captain V2] model resolution ... model=` lo dice en cada turno.
2. **Evolution**: activar `CACHE_REDIS_ENABLED=true` (o `CACHE_LOCAL_ENABLED`) para que
   `createConversation` se cachee 30 min y cada mensaje entrante sea 1 llamada a Chatwoot
   en vez de 3–4. Evolution y Chatwoot en la misma red de Coolify (hostname interno, no
   dominio público) para que esas llamadas no salgan a internet.
3. **Evolution añade 0,5–2 s aleatorios** a cada mensaje saliente (`delay: Math.random()*1500+500`
   en `chatwoot.service.ts`). Está hardcodeado; no hay setting. Asumirlo.
4. **Indicador "escribiendo…"**: Evolution no procesa `conversation_typing_on` de Chatwoot.
   No se puede simular desde aquí sin tocar Evolution.
5. **Índice pgvector**: `vector_idx_knowledge_entries_embedding` es ivfflat con `vector_l2_ops`
   pero la búsqueda usa coseno → no se usa el índice (scan secuencial exacto). Irrelevante
   con cientos de FAQs; si pasan de ~10k, crear un índice HNSW `vector_cosine_ops`.

## Cómo medir (cuando `postgres-prod` responda)

```sql
WITH m AS (
  SELECT m.created_at, m.message_type, m.sender_type, i.name,
         LAG(m.message_type) OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id) prev_type,
         LAG(m.created_at)   OVER (PARTITION BY m.conversation_id ORDER BY m.created_at, m.id) prev_at
  FROM messages m JOIN inboxes i ON i.id = m.inbox_id
  WHERE m.created_at > now() - interval '7 days' AND NOT m.private)
SELECT name, count(*) n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM created_at-prev_at))::numeric,1) p50_s,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM created_at-prev_at))::numeric,1) p90_s
FROM m WHERE message_type=1 AND sender_type='Captain::Assistant' AND prev_type=0
GROUP BY 1 ORDER BY 2 DESC;
```

Mide entrada → respuesta guardada en Chatwoot. Lo que falte hasta el móvil es webhook +
Evolution. Comparar antes/después del despliegue; el debounce suma ~2 s fijos al p50 y a
cambio quita los picos de ráfagas y las respuestas duplicadas.

Los logs `[Captain V2] prefetched N FAQ entries` y `[CAPTAIN][skip] reason=superseded_by_newer_message`
confirman que las dos mejoras principales están actuando.
