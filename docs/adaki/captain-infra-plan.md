# Captain: plan de mejoras de infraestructura del agente

Fecha: 2026-09-05. Complementa `captain-latencia.md` (cambios ya hechos en código).
Aquí va lo que queda: infraestructura, Redis, proveedor y observabilidad, por prioridad.

## Resolución de modelos: la base de datos manda (2026-09-06)

`platform_credential_models` lo escribe `Platform::Models::Importer` **literal**
desde la lista en vivo del proveedor. Es la única fuente de identidad de modelo.
`config/llm.yml` es catálogo de producto (qué proveedores soportamos, nombres
visibles, multiplicadores de crédito, qué ofrece el desplegable) y ya no nombra
ningún modelo en tiempo de ejecución.

Qué se quitó de `Platform::Models::Resolver`:

- `provider_default_slug` y `feature_slug_for_provider`: inventaban un slug del
  catálogo para cuentas sin modelos sincronizados.
- La rama `:preferred_catalog`: emparejaba un slug del catálogo con una
  credencial del mismo proveedor sin fila en base de datos.
- `canonical_slug` sobre filas de base de datos. Lo introdujo `aef830b` y era
  una regresión: reescribía un identificador válido del proveedor con una
  abreviatura nuestra. `gemini-3-pro` apuntaba a `gemini-3-pro-preview`, que
  Google tiene **apagado**.
- `fallback_model` se sigue aceptando por compatibilidad y se ignora.

Qué entró:

- `FEATURE_KINDS`: una feature de Chatwoot mapea a los *kinds* que puede
  servirla, no a una lista de slugs. Los proveedores solo clasifican por kind.
- `CHAT_KINDS = %w[chat multimodal]`. **Importante**: `Importer#classify_kind`
  guarda todo lo que contiene "gemini" o "claude" como `multimodal`, así que una
  búsqueda por `kind: 'chat'` a secas no podía encontrar jamás un modelo Gemini.
  Era un fallo latente.
- `Llm::Models.current_model_slug`: solo remapea endpoints **retirados** por el
  proveedor (los alias V4 de DeepSeek). Es lo único que puede reescribir una
  fila de base de datos, porque un slug retirado es demostrablemente falso.
  `canonical_model_slug` (con las abreviaturas del catálogo) queda para
  preferencias guardadas y para el catálogo.
- `allow_credential_only`: para quien enruta por proveedor y trae su propio
  modelo por defecto (`Captain::Documents::PdfProvider`). Devuelve la credencial
  sin slug, para que una cuenta con clave de Gemini sin sincronizar no acabe en
  la API de archivos de OpenAI.

**Cambio de comportamiento a vigilar.** Una cuenta con credencial activa pero
**cero modelos sincronizados** ya no recibe un slug inventado: el resolver
devuelve `nil` y el llamador cae a su ruta heredada (InstallationConfig y la
configuración global de RubyLLM). El arreglo es un clic: Configuración → Captain
→ sincronizar modelos. Antes "funcionaba" solo mientras el catálogo estuviera
fresco, y ya no lo está.

## Estado actual verificado

| Pieza | Cómo está | Riesgo / oportunidad |
|---|---|---|
| Redis (Coolify) | `redis:alpine`, volumen `redis_data`, sin `--appendonly`, política `noeviction` | Snapshots RDB por defecto (cada 5–60 min). Un crash pierde hasta 1 h de cola Sidekiq: incluye los jobs de Captain retrasados por el debounce → mensajes de clientes sin respuesta, sin error. |
| `Rails.cache` | Sin `cache_store` configurado → FileStore en `tmp/cache` de cada contenedor. **0 usos** en el código | Todo lo que hoy se cachea va por `$alfred` (GlobalConfig, locks, rate limit de grupos, circuit breaker, caché de embeddings). |
| Locks | `Redis::LockManager` + `MutexApplicationJob` existen; Captain no los usa | Dos jobs de Captain pueden correr a la vez sobre la misma conversación (retry + mensaje nuevo, o adjunto con espera + texto). |
| Trazas LLM | OpenTelemetry → Langfuse cableado, se activa con `OTEL_PROVIDER=langfuse` + 3 claves en InstallationConfig (super admin) | Si no está activo en prod, no hay desglose LLM / tools / embeddings por turno. Es la única forma de saber en qué se van los segundos. |
| Prompt | `Current Context` (dinámico) y `knowledge` (dinámico por turno) en medio del system prompt | Rompe el prefix caching implícito de Gemini/OpenAI: cada turno paga el prompt entero. |
| Salida | Sin límite de `maxOutputTokens` | La respuesta de la captura (~350 tokens) tarda 2–4 s solo en generarse. Sin tope, el modelo se alarga. |
| Sidekiq | 1 proceso, 10 hilos: 7 general + 3 capsule `captain` | Las llamadas LLM son I/O: la capsule admite 6 hilos sin coste de CPU. Pool de Postgres se dimensiona con `SIDEKIQ_CONCURRENCY`. |
| pgvector | ivfflat con `vector_l2_ops`; búsqueda por coseno → índice no usado | Irrelevante con cientos de FAQs. HNSW `vector_cosine_ops` si pasan de ~10k. |

## Plan por prioridad

### P0 — sin cambiar código

1. **Redis con AOF** en `docker-compose.coolify.yaml`:
   `redis-server --requirepass "$$REDIS_PASSWORD" --appendonly yes --appendfsync everysec`.
   Cierra el agujero de "cola perdida = clientes sin respuesta". Mantener `noeviction`:
   con `allkeys-lru` Redis podría expulsar colas de Sidekiq para hacer sitio a caché.
2. **Activar Langfuse** (self-hosted en Coolify o cloud): super admin → InstallationConfig
   `OTEL_PROVIDER=langfuse`, `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`.
   Cada turno queda como traza con spans por llamada LLM, tool y embedding, con tokens y
   duración. Antes de tocar nada más, mirar una semana de trazas.
3. **Modelo Gemini 2.5 Flash, razonamiento `off`**, por asistente. Verificar en el log
   `[Captain V2] model resolution ... model=`.
4. **Sidekiq**: `SIDEKIQ_CONCURRENCY=13`, `SIDEKIQ_CAPTAIN_CONCURRENCY=6`. Vigilar la
   latencia de la cola `captain` en `/monitoring/sidekiq`.
5. **Evolution**: `CACHE_REDIS_ENABLED=true` (puede usar el mismo Redis con otro
   `CACHE_REDIS_PREFIX_KEY` y DB index, o el suyo) → 1 llamada API a Chatwoot por mensaje
   entrante en vez de 3–4. Hostname interno de Coolify para hablar con Chatwoot.

### P1 — HECHO (2026-09-05)

Los cuatro implementados con specs. Detalle abajo; lo que sigue vigente es P0 y P2.

6. **Single-flight por conversación con Redis** (`Redis::LockManager`, TTL 90 s):
   `ResponseBuilderJob` toma el lock `captain:conversation:<id>`; si otro job lo tiene, se
   re-encola a +3 s. Al terminar, si llegaron mensajes entrantes durante la llamada al LLM,
   encola un job más. Resultado: nunca dos respuestas simultáneas ni desordenadas, y el
   mensaje que llegó "mientras pensaba" también se responde.
7. **Prompt estable para prefix caching**: sacar `knowledge` del system prompt y adjuntarlo
   al último mensaje del usuario ("Knowledge base results: … / Customer message: …"). El
   system prompt pasa a ser constante por (asistente, canal, conversación) y el proveedor
   cachea system + historial anterior. Gemini 2.5 cobra un 75% menos los tokens cacheados y
   baja el tiempo al primer token. Mismo cambio para OpenAI (cache automática ≥1024 tokens).
8. **Tope de salida por canal**: en canales de chat `maxOutputTokens: 600` (Gemini
   `generationConfig`) / `max_completion_tokens` (OpenAI) vía `Agentable#agent_thinking_params`
   (ya mezcla `generationConfig`). Acompañado en el prompt de "máximo 6–8 líneas; ofrece
   detalle si lo piden". Menos tokens generados = respuesta más rápida y mejor en WhatsApp.
9. **Ventana de historial para WhatsApp**: `history_window_messages` a 16 en los asistentes
   de WhatsApp (config por asistente, ya existe). Menos tokens de entrada por turno.

### P2 — solo si las trazas lo justifican

10. **`Rails.cache` sobre Redis** (`config.cache_store = :redis_cache_store` con
    `Redis::Config.app`, namespace propio, TTL siempre) para: resolución de modelo/credencial
    por cuenta (`Platform::Models::Resolver`, hoy 5–8 queries por turno), `InstallationConfig`
    de Captain (`CAPTAIN_OPEN_AI_MODEL` se lee en cada construcción de agente), lista de
    tools por asistente. Ahorra decenas de ms y carga de Postgres; no segundos.
11. **Caché semántica de respuestas** en Redis: si la pregunta nueva tiene similitud coseno
    > 0,97 con una ya respondida por el mismo asistente en las últimas 24 h, y no hubo
    handoff/tool con efectos, reutilizar la respuesta sin llamar al LLM. Solo para
    conversaciones 1:1 y preguntas factuales. Ahorra la llamada entera, pero puede repetir
    una respuesta que ya no encaja en el hilo: activar solo tras medir cuántas preguntas se
    repiten (Langfuse lo dice).
12. **Proceso Sidekiq dedicado** para la cola `captain` (segundo servicio en el compose
    con `-q captain`): aísla memoria y reinicios de Captain del resto de colas.
13. **HNSW `vector_cosine_ops`** en `captain_assistant_responses` cuando el corpus crezca.

## Para qué sirve Redis aquí (resumen)

- **Ya**: colas Sidekiq (incluido el debounce), GlobalConfig, locks, rate limit de grupos,
  circuit breaker de credenciales, caché de embeddings de búsqueda (24 h).
- **Recomendado**: lock single-flight por conversación (P1.6), `Rails.cache` para
  resolución de modelos/config (P2.10), caché semántica de respuestas (P2.11), caché de
  Evolution (P0.5).
- **No**: guardar historial de conversación (ya está en Postgres y se reconstruye por
  turno) ni sustituir pgvector.

## Orden sugerido

P0 completo esta semana (solo config). Medir una semana con Langfuse. Después P1.6 y P1.7
(los dos con más impacto en latencia percibida y coste), P1.8 y P1.9 en el mismo despliegue.
P2 solo con datos.
