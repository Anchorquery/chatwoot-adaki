# Captain (Chatwoot) — Arquitectura completa para replicar en PHP

Documento técnico exhaustivo. Mapea infraestructura, datos, ingestión, embeddings, generación automática de FAQs y el flujo del bot. Pensado para reescribir Captain en PHP (Laravel/Symfony) manteniendo paridad funcional.

---

## 1. Visión general

Captain = sistema multi‑agente para soporte automatizado. Cuatro bloques:

1. **Knowledge ingestion**: crawl web (sitemap/HTML) + subida PDF.
2. **Knowledge representation**: documentos → FAQs (Q/A) generadas por LLM → embeddings pgvector.
3. **Retrieval**: búsqueda vectorial cosine sobre FAQs aprobadas + tool `search_documentation`.
4. **Agent runtime**: orquestador multi‑agente (assistant + scenarios) con tools, handoff a humano, instrucciones via plantillas Liquid.

Stack original: Rails 7, PostgreSQL + extensión `pgvector`, Sidekiq (jobs), OpenAI (gpt-4.1 / text-embedding-3-small), RubyLLM, Firecrawl opcional.

Stack PHP propuesto: Laravel 11 + Horizon (queues), PostgreSQL + pgvector (`pgvector/pgvector-php`), `openai-php/client`, `league/html-to-markdown`, `symfony/dom-crawler`, Smalot/PdfParser o API Files de OpenAI.

---

## 2. Modelo de datos (replicar tal cual)

Extensión obligatoria: `CREATE EXTENSION IF NOT EXISTS vector;`

### 2.1 `captain_assistants`
```sql
id              bigserial PK
account_id      bigint NOT NULL
name            varchar NOT NULL
description     varchar
config          jsonb NOT NULL    -- temperature, product_name, feature_faq,
                                  --  feature_memory, feature_contact_attributes,
                                  --  autopilot_enabled, instructions, timezone,
                                  --  feature_citation, whatsapp_number...
response_guidelines jsonb         -- array de strings
guardrails          jsonb         -- array de strings
created_at, updated_at
```
Índices: `(account_id)`, `(account_id, name) UNIQUE`.

### 2.2 `captain_documents`
```sql
id                       bigserial PK
account_id               bigint NOT NULL
assistant_id             bigint NOT NULL
name                     varchar
external_link            varchar NOT NULL    -- URL o "PDF: filename_timestamp"
content                  text                -- markdown (máx 200_000)
content_fingerprint      varchar             -- SHA256(content normalizado)
status                   int  default 0      -- 0=in_progress, 1=available
sync_status              int                 -- 0=syncing, 1=synced, 2=failed
last_sync_attempted_at   timestamp
last_synced_at           timestamp
last_sync_error_code     varchar             -- not_found|access_denied|timeout|fetch_failed|content_empty
metadata                 jsonb               -- content_fingerprint, sync_step, openai_file_id,
                                              --  crawl_mode (website|sitemap), crawl_root_url, crawl_depth,
                                              --  faq_generation {method, pages_processed, iterations, timestamp}
created_at, updated_at
```
Índices: `(account_id)`, `(assistant_id)`, `(assistant_id, external_link) UNIQUE`, `(status)`, `(account_id, assistant_id, sync_status, last_synced_at)`.

Adjunto `pdf_file` (Active Storage). En PHP: tabla `media`/disco S3, link a `external_link = 'PDF: <basename>_<timestamp>'`.

### 2.3 `captain_assistant_responses`  (la "FAQ")
```sql
id                bigserial PK
account_id        bigint NOT NULL
assistant_id      bigint NOT NULL
documentable_id   bigint           -- polimórfica
documentable_type varchar          -- 'Captain::Document' u otro origen
question          varchar NOT NULL
answer            text    NOT NULL
embedding         vector(1536)
status            int default 1     -- 0=pending, 1=approved
edited            boolean default false
created_at, updated_at
```
Índices: `(account_id)`, `(assistant_id)`, `(status)`, `(documentable_id, documentable_type)`, **índice IVFFlat sobre `embedding`**:
```sql
CREATE INDEX vector_idx_knowledge_entries_embedding
  ON captain_assistant_responses USING ivfflat (embedding vector_l2_ops);
```
Búsqueda real corre con distancia **cosine** (`has_neighbors :embedding, normalize: true` + `nearest_neighbors(:embedding, vec, distance: 'cosine')`). En PHP:
```sql
SELECT *, 1 - (embedding <=> :vec) AS score
FROM captain_assistant_responses
WHERE assistant_id = :aid AND status = 1
ORDER BY embedding <=> :vec
LIMIT 5;
```
(`<=>` = cosine distance en pgvector. Normaliza el vector antes de insertar para que cosine ≈ inner product.)

---

## 3. Pipeline de ingestión

### 3.1 Entrada
Crear `Captain::Document` por:
- **URL única** → crawl simple (1 página) o crawl recursivo si `crawl_mode` se setea.
- **URL raíz + crawl_depth** → crawl masivo (mismo origin, hasta N páginas).
- **Sitemap .xml** → extrae `<loc>` y procesa cada URL.
- **PDF** → subida directa.

Validaciones (modelo):
- `external_link` único por assistant (excepto PDF que recibe sufijo timestamp).
- URL http/https válida.
- `content` ≤ 200_000 chars.
- PDF ≤ 10 MB, content_type `application/pdf`.
- Plan limit: cuenta tiene `usage_limits[:captain][:documents][:current_available]`.

### 3.2 Hooks del modelo (orden crítico)
```
before_validation: set account_id, set external_link if PDF, normalize URL (sin trailing /)
before_create: ensure_within_plan_limit
after_create_commit: CrawlJob.perform_later(self) + update_document_usage
after_commit: ResponseBuilderJob.perform_later(self)  -- si available && content presente
```

En PHP: usar eventos Eloquent `creating`, `created`, `saved`. Dispatch a `Queue::push(...)`.

### 3.3 `CrawlJob` — bifurcación
```
if document.pdf_document?         => PdfProcessingService.process (sube a OpenAI Files API)
elsif firecrawl_api_key presente   => FirecrawlService (async, webhook)
else                              => SimplePageCrawlService (HTTP + Nokogiri)
```

### 3.4 SimplePageCrawl (camino sin Firecrawl)
1. Descarga la URL raíz (`SafeFetch.fetch`, con validación SSRF — bloquea IPs privadas).
2. Si termina en `.xml` ⇒ sitemap: extrae `<loc>`.
3. Si HTML ⇒ extrae `<a href>`, filtra **mismo scheme+host+port**, normaliza (sin fragment, sin trailing `/`).
4. `crawl_limit = min(crawl_depth solicitado, plan disponible)`.
5. Encola `SimplePageCrawlParserJob` por cada link + uno para la raíz.

### 3.5 `SimplePageCrawlParserJob`
Para cada URL:
- Reconsulta plan limit (puede haberse agotado entre jobs).
- Fetch HTML con `SafeFetch`.
- Parsea: `title` (`<title>`), `body_markdown` (Nokogiri `<body>` → ReverseMarkdown).
- `find_or_initialize_by(external_link: normalized)` y `update!`:
  - `name = title[0..254]`
  - `content = markdown[0..14_999]` (¡recorta a 15 K, no a 200 K como `SinglePageFetcher`!)
  - `status = available`, `sync_status = synced`, `last_synced_at = now`
  - `metadata.crawl_mode`, `crawl_root_url`, `crawl_depth`.
- Error → marca `sync_status = failed` + `last_sync_error_code`. Códigos: 404→`not_found`, 401/403→`access_denied`, 408/504→`timeout`, otros→`fetch_failed`. Estos tres son **permanentes**: `not_found`, `access_denied`, `content_empty` ⇒ no se reintenta.

### 3.6 Sync periódico (`Captain::Documents::SyncService`)
Para documentos no‑PDF, recorre todos los `available`, computa nuevo `SHA256(content normalizado)`:
- Si igual al `content_fingerprint` previo → `mark_synced`, devuelve `:unchanged`.
- Si distinto → `update_content`, devuelve `:updated`. (Sin fingerprint previo trata como `:unchanged` para no disparar regeneración de FAQs.)

Programado por `Captain::Documents::ScheduleSyncsJob` (corre cron-like; usa scope `stale` = `sync_failed` o `synced` con `last_synced_at < hora_de_corte`).

### 3.7 PDF
`PdfProcessingService.process`:
1. Si `metadata.openai_file_id` ya existe → noop.
2. Crea tempfile, copia el blob, `client.files.upload(purpose: 'assistants')`.
3. Guarda `openai_file_id` en metadata.
4. CrawlJob marca `status = available`. **No setea content**; el flujo paginado lee el file remoto.

En PHP: API equivalente `POST /v1/files` con `purpose=assistants` usando `openai-php/client`.

---

## 4. Generación automática de FAQs

Disparada por `after_commit` en `Captain::Document` cuando se vuelve `available` o cuando cambia `content`.

`Captain::Documents::ResponseBuilderJob`:
```
reset_previous_responses(doc)               -- borra responses NO editadas
faqs = doc.pdf? && openai_file_id ? PaginatedFaqGenerator.generate
                                    : FaqGeneratorService.generate
faqs.each { create_response(...) }
```

### 4.1 `FaqGeneratorService` (texto plano)
- Modelo: `CAPTAIN_OPEN_AI_MODEL` (default `gpt-4.1`), temperature `1.0`.
- `response_format: { type: 'json_object' }`.
- System prompt = `SystemPromptsService.faq_generator(language)` (lo cito íntegro abajo).
- User content = `document.content` (markdown).
- Parsea JSON, devuelve `faqs[]`. Robustez: helper `sanitize_json_response` quita ` ```json ` wrappers.

### 4.2 `PaginatedFaqGeneratorService` (PDF con `openai_file_id`)
Loop con cota dura (`MAX_ITERATIONS = 20`):
```
current_page = 1
while:
  end_page = current_page + pages_per_chunk - 1   # default 10
  result   = process_page_chunk(current_page, end_page)
  all_faqs += result.faqs
  total_pages_processed = end_page
  iterations += 1
  break unless should_continue?(result)
  current_page = end_page + 1
```
`should_continue?` = no superó `MAX_ITERATIONS`, no llegó a `max_pages`, no recibió `faqs: []`, no recibió `has_content: false`.

Cada chunk manda al modelo `gpt-4.1-mini` un mensaje multimodal:
```json
{ "role": "user", "content": [
  { "type": "file", "file": { "file_id": "<openai_file_id>" } },
  { "type": "text", "text": "<paginated_faq_generator prompt for start..end>" }
]}
```
El prompt pide responder `{"faqs":[...], "has_content": true|false}`. Tras todo el loop hay **deduplicación**:
1. `uniq` por `question.downcase.strip`.
2. Similarity = Jaccard de palabras `>0.85` ⇒ descarta.

Persistencia (`store_paginated_metadata`):
```json
"faq_generation": { "method":"paginated", "pages_processed":N, "iterations":I, "timestamp":"..." }
```

### 4.3 Prompts (literal — replicarlos textualmente)

**`faq_generator`** (idioma parametrizable): obliga JSON `{"faqs":[{"question":"","answer":""}]}`, exige completitud, prohíbe FAQs de mero redireccionamiento, prohíbe chrome (header/footer/cookies), idioma único, sin invenciones. Cuando no hay contenido apto: `{"faqs": []}`.

**`paginated_faq_generator(start_page, end_page, language)`**: instruye al modelo a procesar un rango lógico del PDF (no imprime números de página en las respuestas), genera 5‑10 FAQs por página, devuelve `has_content:false` al agotarse.

**`conversation_faq_generator`** (uso secundario en `Captain::Llm::ConversationFaqService`): convierte transcripts agente↔cliente en FAQs. Filtra mensajes del bot.

### 4.4 `create_response` y embedding
```ruby
document.responses.create!(
  question:, answer:, assistant: doc.assistant, documentable: doc
)
```
Hooks del modelo `AssistantResponse`:
- `before_validation` set `account_id`, `status = approved` default.
- `mark_as_edited` (en update) → flag para que el reset del ResponseBuilder no borre lo curado a mano.
- **`after_commit :update_response_embedding`** si cambió question/answer o el embedding está vacío:
  ```ruby
  Captain::Llm::UpdateEmbeddingJob.perform_later(self, "#{question}: #{answer}")
  ```
  El job calcula embedding y `record.update!(embedding: vector)`.

Por eso "incrusta muy rápido": no es un cron — cada FAQ creada dispara su propio job en cola `low` que llama una sola vez a `text-embedding-3-small`. Cientos de FAQs ⇒ cientos de jobs paralelos.

### 4.5 `EmbeddingService`
```ruby
def get_embedding(content, model: 'text-embedding-3-small')
  RubyLLM.embed(content, model: model).vectors
end
```
Endpoint OpenAI: `POST /v1/embeddings` con `{"model":"text-embedding-3-small","input":"..."}` → array de 1536 floats.

---

## 5. Recuperación (cómo el bot encuentra respuestas)

### 5.1 Búsqueda
`Captain::AssistantResponse.search(query, account_id:)`:
1. `embedding = EmbeddingService.get_embedding(query)` (mismo modelo que ingestión).
2. `nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(5)`.

Scope `approved` se aplica antes (`@assistant.responses.approved.search(query)`).

### 5.2 Tool `search_documentation` (expuesto al LLM)
```
1. translated_query = TranslateQueryService.translate(query, target: account locale)
   - Detecta idioma con CLD3; si ya está en idioma destino devuelve query original.
   - Si no, gpt-4.1-nano traduce.
2. responses = assistant.responses.approved.search(translated_query)
3. Renderiza por response:
     Question: ...
     Answer: ...
     Source: <external_link>  (si existe y no es 'PDF:')
   Concatena las 5.
4. Si vacío: "No FAQs found for the given query"
```

### 5.3 Tool `faq_lookup` (variante interna idéntica)
Mismo flujo, sin traducción previa. Lo usa el assistant cuando ya está en el contexto correcto.

---

## 6. Runtime del bot (agente)

### 6.1 Arquitectura multi‑agente
- Cada `Captain::Assistant` incluye `Concerns::Agentable` ⇒ expone `.agent` (un `Agents::Agent`).
- Cada `Captain::Scenario` también es Agentable ⇒ produce un sub‑agente.
- `AgentRunnerService` cablea:
  ```
  assistant_agent.register_handoffs(*scenario_agents)
  scenario_agents.each { |s| s.register_handoffs(assistant_agent) }
  runner = Agents::Runner.with_agents(assistant_agent, *scenario_agents)
  result = runner.run(message, context:, max_turns: 100)
  ```

El SDK `agents` (Ruby) hace tool‑use loop con OpenAI function calling, soporta handoffs entre agentes, callbacks `on_tool_complete`, `on_run_complete`.

### 6.2 Instrucciones (prompt) del assistant
Plantilla Liquid `enterprise/lib/captain/prompts/assistant.liquid`. Variables interpoladas desde `prompt_context`:
- `name`, `description`, `product_name`
- `scenarios` (lista de `{title, key, description}`)
- `response_guidelines[]`, `guardrails[]`
- `conversation`, `contact` (si `feature_contact_attributes`), `campaign` (via snippets Liquid)

Reglas clave que la plantilla impone al LLM:
- Primero buscar conocimiento con `search_documentation` y verificar con `captain--tools--faq_lookup`.
- Si falta info, **una sola** pregunta de clarificación.
- Si no encuentra respuesta y el usuario insiste ⇒ `captain--tools--handoff` (transfer humano).
- Detecta y replica idioma del usuario.
- No usar conocimiento propio del LLM.

### 6.3 Tools registradas (registry)
`Captain::Tools::RegistryService.assistant_tools` devuelve a) toda tool nativa habilitada para ese assistant, b) MCP tools, c) custom_http tools. Tools de fábrica en `enterprise/lib/captain/tools/`:
- `faq_lookup_tool` — búsqueda vectorial sobre FAQs.
- `handoff_tool` — marca conversación para transferencia humana (flag `captain_v2_handoff_tool_called` en context).
- `add_private_note_tool`, `add_contact_note_tool`, `add_label_to_conversation_tool`, `update_priority_tool`, `resolve_conversation_tool`.
- `http_tool` — HTTP genérico configurable.
- `mcp_tool` — proxy a servers MCP.

Plus tool de servicio:
- `search_documentation_service` (la que el system prompt menciona). Es servicio + clase tool.

### 6.4 Action classifier (decide handoff antes de responder)
`Captain::Llm::AssistantActionClassifierService` con prompt `assistant_action_classifier`. Devuelve `{action: continue|handoff, action_reason: ...}`. Si `handoff`, no se llama al runner; se entrega la conversación a humano.

### 6.5 Flujo end‑to‑end de un mensaje entrante
```
Incoming user message
  ↓
Conversation::ResponseBuilderJob (captain v2)
  ↓
ActionClassifierService → continue | handoff
  ↓ continue
AgentRunnerService.generate_response(message_history)
  build_context(state: account_id, assistant_id, assistant_config,
                conversation, contact, campaign, channel_type, source)
  runner.run(last_user_msg, context:, max_turns: 100)
    └─ LLM tool loop:
         search_documentation(query)   ← embedding + cosine top-5
         faq_lookup(query)              ← embedding + cosine top-5
         <scenario handoff>             ← cambia agente activo
         <handoff_tool>                 ← marca conversación
    └─ resultado: { response, reasoning, agent_name, handoff_tool_called }
  ↓
Persist como mensaje del assistant; si handoff_tool_called o response == 'conversation_handoff' → notifica humano.
```

---

## 7. Configuración

`InstallationConfig` (key‑value en DB) — replicar como tabla `installation_configs(name, value, locked)` o `config/captain.php`:

| Clave | Valor por defecto | Uso |
|---|---|---|
| `CAPTAIN_OPEN_AI_API_KEY` | — | Token OpenAI |
| `CAPTAIN_OPEN_AI_ENDPOINT` | `https://api.openai.com/` | Endpoint custom (Azure, proxy) |
| `CAPTAIN_OPEN_AI_MODEL` | `gpt-4.1` | Chat principal |
| `CAPTAIN_EMBEDDING_MODEL` | `text-embedding-3-small` | Embeddings (1536 dims) |
| `CAPTAIN_FIRECRAWL_API_KEY` | — | Si presente, usa Firecrawl en lugar del crawler simple |

Modelos especiales hardcoded:
- `gpt-4.1-mini` → PDF paginated FAQ.
- `gpt-4.1-nano` → traducción de queries.

Account `config` (JSONB): `temperature`, `product_name`, `feature_faq`, `feature_memory`, `feature_contact_attributes`, `feature_citation`, `instructions`, `timezone`, `autopilot_enabled`.

---

## 8. Mapeo a PHP (Laravel concreto)

### 8.1 Dependencias composer
```json
{
  "openai-php/client": "^0.10",
  "pgvector/pgvector": "^0.2",
  "league/html-to-markdown": "^5.1",
  "symfony/dom-crawler": "^7.0",
  "symfony/css-selector": "^7.0",
  "guzzlehttp/guzzle": "^7.8",
  "smalot/pdfparser": "^2.10",   // opcional si no se sube a OpenAI Files
  "laravel/horizon": "^5.0"
}
```

### 8.2 Migraciones
```php
DB::statement('CREATE EXTENSION IF NOT EXISTS vector');

Schema::create('captain_assistants', function (Blueprint $t) {
    $t->id();
    $t->unsignedBigInteger('account_id');
    $t->string('name');
    $t->string('description')->nullable();
    $t->jsonb('config');
    $t->jsonb('response_guidelines')->nullable();
    $t->jsonb('guardrails')->nullable();
    $t->timestamps();
    $t->unique(['account_id','name']);
});

Schema::create('captain_documents', function (Blueprint $t) {
    $t->id();
    $t->unsignedBigInteger('account_id');
    $t->unsignedBigInteger('assistant_id');
    $t->string('name')->nullable();
    $t->string('external_link');
    $t->text('content')->nullable();
    $t->string('content_fingerprint')->nullable();
    $t->unsignedTinyInteger('status')->default(0);   // 0 in_progress, 1 available
    $t->unsignedTinyInteger('sync_status')->nullable();
    $t->timestamp('last_sync_attempted_at')->nullable();
    $t->timestamp('last_synced_at')->nullable();
    $t->string('last_sync_error_code')->nullable();
    $t->jsonb('metadata')->nullable();
    $t->timestamps();
    $t->unique(['assistant_id','external_link']);
    $t->index(['account_id','assistant_id','sync_status','last_synced_at']);
});

Schema::create('captain_assistant_responses', function (Blueprint $t) {
    $t->id();
    $t->unsignedBigInteger('account_id');
    $t->unsignedBigInteger('assistant_id');
    $t->morphs('documentable');
    $t->string('question');
    $t->text('answer');
    $t->unsignedTinyInteger('status')->default(1);   // 1 approved, 0 pending
    $t->boolean('edited')->default(false);
    $t->timestamps();
});
DB::statement('ALTER TABLE captain_assistant_responses ADD COLUMN embedding vector(1536)');
DB::statement('CREATE INDEX vector_idx_knowledge_entries_embedding
               ON captain_assistant_responses USING ivfflat (embedding vector_l2_ops)');
```

Tip: usa `WITH (lists=100)` cuando tengas >10k filas; antes deja default. Para `cosine` real puedes crear `vector_cosine_ops` index si normalizas:
```sql
CREATE INDEX ON captain_assistant_responses USING ivfflat (embedding vector_cosine_ops);
```

### 8.3 Model `CaptainAssistantResponse`
```php
protected static function booted(): void
{
    static::creating(function ($r) {
        $r->account_id ??= $r->assistant->account_id;
        $r->status ??= 1;
    });

    static::updating(function ($r) {
        if ($r->isDirty('question') || $r->isDirty('answer')) $r->edited = true;
    });

    static::saved(function ($r) {
        if ($r->wasChanged(['question','answer']) || is_null($r->embedding)) {
            UpdateEmbeddingJob::dispatch($r->id, "{$r->question}: {$r->answer}")
                ->onQueue('low');
        }
    });
}

public static function searchByEmbedding(int $assistantId, array $vec, int $k = 5): Collection
{
    $literal = '[' . implode(',', $vec) . ']';
    return self::query()
        ->where('assistant_id', $assistantId)
        ->where('status', 1)
        ->selectRaw('*, 1 - (embedding <=> ?::vector) as score', [$literal])
        ->orderByRaw('embedding <=> ?::vector', [$literal])
        ->limit($k)->get();
}
```

### 8.4 `EmbeddingService`
```php
final class EmbeddingService
{
    public function __construct(private OpenAI\Client $client) {}

    public function embed(string $content, string $model = 'text-embedding-3-small'): array
    {
        if ($content === '') return [];
        $r = $this->client->embeddings()->create(['model' => $model, 'input' => $content]);
        return $r->embeddings[0]->embedding;   // float[1536]
    }
}
```

### 8.5 `UpdateEmbeddingJob`
```php
public function handle(EmbeddingService $svc): void
{
    $r = CaptainAssistantResponse::find($this->id);
    if (!$r) return;
    $vec = $svc->embed($this->content);
    $literal = '[' . implode(',', $vec) . ']';
    DB::update('UPDATE captain_assistant_responses SET embedding = ?::vector WHERE id = ?', [$literal, $r->id]);
}
```

### 8.6 Crawler simple
```php
final class SimplePageCrawl
{
    public function __construct(private string $url) {
        $this->html = $this->fetch();
        $this->dom  = new Crawler($this->html, $this->url);
    }
    public function title(): ?string {
        return trim((string) $this->dom->filterXPath('//title')->text(''));
    }
    public function bodyMarkdown(): string {
        $body = $this->dom->filterXPath('//body')->html('');
        return (new HtmlConverter(['strip_tags' => true]))->convert($body);
    }
    public function pageLinks(): array {
        if (str_ends_with($this->url, '.xml')) return $this->fromSitemap();
        return $this->fromAnchors();
    }
    // sameOrigin + normalize (sin fragment, sin trailing /)
}
```
SSRF: antes de `Guzzle::get`, resuelve DNS, rechaza IPs `127.0.0.0/8`, `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, link‑local. Replica `SafeFetch`.

### 8.7 Job `CrawlPageJob`
```php
public function handle(): void
{
    $crawl = new SimplePageCrawl($this->pageLink);
    if (!$crawl->success()) { /* mark sync_status=failed */ return; }
    $doc = CaptainDocument::firstOrNew([
        'assistant_id'  => $this->assistantId,
        'external_link' => $this->normalize($this->pageLink),
    ]);
    $doc->fill([
        'name'    => mb_substr($crawl->title() ?? '', 0, 254),
        'content' => mb_substr($crawl->bodyMarkdown(), 0, 14_999),
        'status'  => 1,
        'sync_status' => 1,
        'last_synced_at' => now(),
        'metadata' => array_merge($doc->metadata ?? [], [
            'crawl_mode' => $this->crawlMode ?? 'website',
            'crawl_root_url' => $this->crawlRoot,
            'crawl_depth' => $this->crawlDepth,
        ]),
    ])->save();   // dispara observer → FaqResponseBuilderJob
}
```

### 8.8 `FaqGeneratorService` (PHP)
```php
public function generate(CaptainDocument $doc): array
{
    $r = $this->client->chat()->create([
        'model' => config('captain.chat_model', 'gpt-4.1'),
        'response_format' => ['type' => 'json_object'],
        'temperature' => 1.0,
        'messages' => [
            ['role' => 'system', 'content' => SystemPrompts::faqGenerator($doc->account->localeEnglishName())],
            ['role' => 'user', 'content' => $doc->content],
        ],
    ]);
    $content = $this->stripFences($r->choices[0]->message->content);
    return json_decode($content, true)['faqs'] ?? [];
}
```

### 8.9 `PaginatedFaqGeneratorService`
Misma estructura del Ruby: loop con `MAX_ITERATIONS=20`, `pages_per_chunk=10`, content multimodal con `{"type":"file","file":{"file_id":...}}`. `openai-php/client` aún no expone `file` block dentro de mensajes en helpers; usar `withHttpRequest` o llamada raw:
```php
$resp = $http->post('https://api.openai.com/v1/chat/completions', [
    'headers' => ['Authorization' => "Bearer $key"],
    'json' => [
        'model' => 'gpt-4.1-mini',
        'response_format' => ['type' => 'json_object'],
        'messages' => [[
            'role' => 'user',
            'content' => [
                ['type' => 'file', 'file' => ['file_id' => $doc->metadata['openai_file_id']]],
                ['type' => 'text', 'text' => SystemPrompts::paginatedFaqGenerator($start, $end, $lang)],
            ],
        ]],
    ],
]);
```
Dedup post‑loop: lowercase+trim, Jaccard>0.85 ⇒ descartar.

### 8.10 `FaqResponseBuilderJob`
```php
public function handle(): void
{
    $doc = CaptainDocument::find($this->id);
    // borra responses no editadas
    $doc->responses()->where('edited', false)->delete();

    $faqs = $doc->isPdf() && !empty($doc->metadata['openai_file_id'])
        ? app(PaginatedFaqGeneratorService::class)->generate($doc)
        : app(FaqGeneratorService::class)->generate($doc);

    foreach ($faqs as $faq) {
        $doc->responses()->create([
            'assistant_id' => $doc->assistant_id,
            'question'     => $faq['question'],
            'answer'       => $faq['answer'],
        ]); // observer dispara embedding
    }
}
```

### 8.11 Tool `SearchDocumentation` (function calling con OpenAI)
Schema enviado al modelo:
```json
{
  "type": "function",
  "function": {
    "name": "search_documentation",
    "description": "Search and retrieve documentation from knowledge base",
    "parameters": {
      "type": "object",
      "properties": { "query": { "type": "string" } },
      "required": ["query"]
    }
  }
}
```
Handler PHP:
```php
function searchDocumentation(string $query, CaptainAssistant $a, EmbeddingService $emb): string
{
    $translated = app(TranslateQueryService::class)->translate($query, $a->account->localeEnglishName());
    $vec = $emb->embed($translated);
    $rows = CaptainAssistantResponse::searchByEmbedding($a->id, $vec, 5);
    if ($rows->isEmpty()) return 'No FAQs found for the given query';
    return $rows->map(fn($r) =>
        "        Question: {$r->question}\n        Answer: {$r->answer}\n" .
        ($r->documentable && $r->documentable->external_link && !str_starts_with($r->documentable->external_link,'PDF:')
            ? "          Source: {$r->documentable->external_link}\n" : '')
    )->implode('');
}
```

### 8.12 Bot loop
Como `openai-php/client` no tiene un Runner multi‑agente, implementa el loop manual:
```php
$messages = [
    ['role' => 'system', 'content' => $renderedLiquidPrompt],
    ...$history,
    ['role' => 'user', 'content' => $userMsg],
];
$tools = $registry->openaiToolSchemas($assistant);

for ($turn = 0; $turn < 100; $turn++) {
    $r = $openai->chat()->create([
        'model' => 'gpt-4.1', 'temperature' => $assistant->temperature(),
        'tools' => $tools, 'tool_choice' => 'auto',
        'response_format' => ['type'=>'json_schema','json_schema'=>$responseSchema], // {reasoning, response}
        'messages' => $messages,
    ]);
    $msg = $r->choices[0]->message;
    if ($msg->toolCalls) {
        $messages[] = $msg->toArray();
        foreach ($msg->toolCalls as $call) {
            $out = $registry->execute($call->function->name, json_decode($call->function->arguments, true), $ctx);
            $messages[] = ['role'=>'tool','tool_call_id'=>$call->id,'content'=>$out];
            if ($call->function->name === 'captain--tools--handoff') $ctx['handoff'] = true;
        }
        continue;
    }
    return ['response' => json_decode($msg->content, true), 'handoff' => $ctx['handoff'] ?? false];
}
```

Handoff a scenario = otro tool `handoff_to_<scenario_key>` que reemplaza el `system` por el prompt del scenario y reinicia el loop con el mismo history.

### 8.13 Plantillas
Para Liquid en PHP: `liquid/liquid` (Harro). O reescribe `assistant.liquid` como Blade. Mantén las variables: `name, description, product_name, scenarios[{title,key,description}], response_guidelines[], guardrails[], conversation, contact, campaign`.

### 8.14 Action classifier
Idéntico a Ruby. Llama a `gpt-4.1` con prompt `assistant_action_classifier` y `response_format` JSON schema:
```json
{"type":"object","properties":{"action":{"enum":["continue","handoff"]},"action_reason":{"type":"string"}},"required":["action","action_reason"]}
```

---

## 9. Detalles que normalmente se rompen al replicar

1. **Cosine vs L2.** El índice IVFFlat original está con `vector_l2_ops` pero la query corre `distance: 'cosine'`. Si normalizas vectores (lo hace `has_neighbors :embedding, normalize: true`), L2 y cosine ordenan igual. En PHP: o normalizas en `embed()` (dividir por `sqrt(Σx²)`) y dejas IVFFlat L2, **o** creas índice con `vector_cosine_ops` y omites normalización. Elige uno y aplícalo consistentemente en ingestión y consulta.

2. **Tamaño del content guardado.** El modelo valida ≤200 000; el crawler simple recorta a 15 000; el fetcher (sync periódico) recorta a 200 000. **Replica los dos límites distintos**: 15 000 al crear desde crawler masivo, 200 000 al resincronizar página única.

3. **`edited` flag.** La regeneración (`reset_previous_responses`) **NO** borra responses con `edited=true`. Sin esto, un admin que corrija manualmente una FAQ verá su edición destruida en el próximo crawl. Indispensable.

4. **Fingerprint normalizado.** `SHA256(content.gsub(/\s+/, ' ').strip)`. Sin normalizar, cualquier diferencia en saltos de línea redispara FAQs (caro).

5. **Primera sincronización sin fingerprint** ⇒ devuelve `:unchanged` aunque haya cambios — evita una regeneración inútil cuando se rellena baseline.

6. **`status=approved` por defecto** en assistant_responses. Si tu UI requiere moderación humana, cámbialo a `pending` y filtra en `search`. Hoy todo lo generado por LLM se publica automáticamente.

7. **PDF `external_link`** se construye como `"PDF: <basename>_<YmdHis>"` para mantener la unicidad (el índice es `(assistant_id, external_link) UNIQUE`). En PHP usa el mismo formato; el bot reconoce `startsWith('PDF:')` para ocultar el "source" en las respuestas.

8. **`SafeFetch` (SSRF).** En PHP, valida URL antes del HTTP. Bloquea hosts internos, redirecciones a IPs privadas, content‑length excesivo (>5 MB), content‑type no deseado. Sin esto el crawler es un proxy abierto.

9. **Idempotencia de jobs.** `CrawlJob` se reencola con cada `after_create_commit`; pero la regeneración de FAQs sólo dispara si `status=available` y `(saved_change_to_status? || saved_change_to_content?) && content.present?`. Replica esa guarda — sin ella vas a re‑embedear infinito.

10. **Errores permanentes vs transitorios.** `PERMANENT_ERROR_CODES = ['not_found','access_denied','content_empty']` ⇒ `discard_on PermanentCrawlError` (no retry). El resto se reintenta con backoff exponencial. En Laravel: tira excepción específica + `public function retryUntil(){ return now()->addHours(2); }`.

11. **Translate antes de buscar.** Si la base se generó en inglés y el usuario escribe en español, sin traducir baja la precisión vectorial. CLD3 detecta idioma; si no coincide con `account.locale`, traduce con gpt-4.1-nano.

12. **Embeddings vacíos.** El job se dispara si `embedding IS NULL` aunque question/answer no hayan cambiado. Necesario para curar FAQs creadas antes de tener API key configurada.

---

## 10. Orden de implementación recomendado (PHP)

1. Schema + pgvector + modelos Eloquent.
2. `EmbeddingService` + `UpdateEmbeddingJob` + observer → probar a mano insertando una FAQ.
3. `SimplePageCrawl` + `CrawlPageJob` (sin FAQ aún) → comprobar que se guarda content markdown.
4. `FaqGeneratorService` con prompt literal del paso 4.3.
5. `FaqResponseBuilderJob` enganchado a observer de Document.
6. Tool `search_documentation` + endpoint de prueba `/captain/search?q=...`.
7. Loop del bot con function calling y plantilla Liquid del prompt.
8. `PaginatedFaqGeneratorService` (PDF) — último, sólo si necesitas PDFs largos.
9. Action classifier + handoff humano + WebSocket/push al frontend.

---

## 11. Archivos de referencia (Chatwoot)

| Concepto | Archivo |
|---|---|
| Modelo Assistant | [enterprise/app/models/captain/assistant.rb](enterprise/app/models/captain/assistant.rb) |
| Modelo Document | [enterprise/app/models/captain/document.rb](enterprise/app/models/captain/document.rb) |
| Modelo Response (FAQ + vector) | [enterprise/app/models/captain/assistant_response.rb](enterprise/app/models/captain/assistant_response.rb) |
| EmbeddingService | [enterprise/app/services/captain/llm/embedding_service.rb](enterprise/app/services/captain/llm/embedding_service.rb) |
| UpdateEmbeddingJob | [enterprise/app/jobs/captain/llm/update_embedding_job.rb](enterprise/app/jobs/captain/llm/update_embedding_job.rb) |
| FAQ generator (texto) | [enterprise/app/services/captain/llm/faq_generator_service.rb](enterprise/app/services/captain/llm/faq_generator_service.rb) |
| FAQ paginado (PDF) | [enterprise/app/services/captain/llm/paginated_faq_generator_service.rb](enterprise/app/services/captain/llm/paginated_faq_generator_service.rb) |
| ResponseBuilderJob (FAQ→FAQ rows) | [enterprise/app/jobs/captain/documents/response_builder_job.rb](enterprise/app/jobs/captain/documents/response_builder_job.rb) |
| CrawlJob bifurcador | [enterprise/app/jobs/captain/documents/crawl_job.rb](enterprise/app/jobs/captain/documents/crawl_job.rb) |
| Crawler simple | [enterprise/app/services/captain/tools/simple_page_crawl_service.rb](enterprise/app/services/captain/tools/simple_page_crawl_service.rb) |
| Crawl parser job | [enterprise/app/jobs/captain/tools/simple_page_crawl_parser_job.rb](enterprise/app/jobs/captain/tools/simple_page_crawl_parser_job.rb) |
| Sync service | [enterprise/app/services/captain/documents/sync_service.rb](enterprise/app/services/captain/documents/sync_service.rb) |
| PDF a OpenAI Files | [enterprise/app/services/captain/llm/pdf_processing_service.rb](enterprise/app/services/captain/llm/pdf_processing_service.rb) |
| Prompts (FAQ + bot) | [enterprise/app/services/captain/llm/system_prompts_service.rb](enterprise/app/services/captain/llm/system_prompts_service.rb) |
| Plantilla Liquid bot | [enterprise/lib/captain/prompts/assistant.liquid](enterprise/lib/captain/prompts/assistant.liquid) |
| Tool search_documentation | [enterprise/app/services/captain/tools/search_documentation_service.rb](enterprise/app/services/captain/tools/search_documentation_service.rb) |
| Tool faq_lookup | [enterprise/lib/captain/tools/faq_lookup_tool.rb](enterprise/lib/captain/tools/faq_lookup_tool.rb) |
| Runner | [enterprise/app/services/captain/assistant/agent_runner_service.rb](enterprise/app/services/captain/assistant/agent_runner_service.rb) |
| Constantes LLM | [lib/llm_constants.rb](lib/llm_constants.rb) |
| Migración inicial captain | [db/migrate/20250104200055_create_captain_tables.rb](db/migrate/20250104200055_create_captain_tables.rb) |

Fin.
