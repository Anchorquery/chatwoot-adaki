# Captain — Puerta de aclaración para el primer mensaje genérico

## Problema

El botón de WhatsApp de una web abre el chat con un texto enlatado del tipo
"Hola, quiero más información sobre sus productos". Ese mensaje no nombra
producto ni tema, pero el turno LLM igualmente:

1. pasa por el pre-enrutado de escenarios (`ScenarioRouter`, ≥ 2 palabras);
2. inyecta hasta 5 FAQs por prefetch (`KnowledgePrefetcher`) con la
   instrucción de responder con ellas en el mismo turno;
3. si el prefetch viene vacío, el prompt (`assistant.liquid`) manda buscar
   primero con `faq_lookup`, y la búsqueda siempre devuelve 5 resultados.

Resultado: el asistente contesta con enlaces de producto en vez de preguntar
qué quiere el cliente. La línea del prompt que pide "haz preguntas
aclaratorias" pierde contra las instrucciones de buscar y contra el resultado
de la tool. Un arreglo solo de prompt no es determinista entre proveedores,
no es testeable unitariamente y sigue pagando un turno LLM completo (8-11 s)
por un mensaje que no lo necesita.

## Solución: `Captain::Conversation::ClarificationGate`

Puerta determinista evaluada en `ResponseBuilderJob#dispatch_response`, antes
de V1/V2 y después del lock, de `conversation_captain_controllable?`, del
debounce (ve la ráfaga entera), del circuit breaker y del check de
credencial.

Dispara solo si se cumple TODO:

- habilitada en el asistente (`config['clarification_gate_enabled']`, default
  `true`);
- primer turno del bot: ningún outgoing público en la conversación (las de
  campaña ya tienen uno, quedan fuera) y sin marcador
  `captain_clarification_asked_at` en `additional_attributes`;
- la ráfaga (todos los incoming públicos, al no haber outgoing) tiene entre 2
  y 12 palabras, sin dígitos, sin URL y sin adjuntos;
- tras normalizar (minúsculas, `I18n.transliterate`, sin puntuación ni
  emoji) TODOS los tokens están en el vocabulario genérico es/en/pt
  (saludos, cortesía, "quiero/necesito/me gustaría", "saber/información/
  detalles/precios/productos/servicios/catálogo", conectores).

Un solo token fuera de la lista (nombre de producto, marca, typo) → no es
genérico → va al LLM. La allow-list es la protección contra falsos positivos:
solo puede gatear texto hecho íntegramente de relleno. Un mensaje de una sola
palabra ("hola", "info") sigue el camino de siempre, igual que
`ScenarioRouter::MIN_QUERY_WORDS`.

### Respuesta

`config['clarification_message']` del asistente; si está vacío, i18n
`conversations.captain.clarification_prompt` (es/en) en el locale de la
cuenta. Se crea con `create_outgoing_message` (pasa por
`ChatTextFormatter`), con `agent_name = clarification_gate`, y se estampa el
marcador para preguntar una sola vez por conversación.

Efectos deliberados:

- `@response` lleva `action_source: 'clarification_gate'` y `timing` a cero;
  `record_captain_v2_usage!` retorna sin registrar tokens.
- No se llama a `increment_response_usage` ni a
  `CredentialCircuitBreaker.record_success!`: no hubo LLM.
- Log `[CAPTAIN][gate] account=… conversation=… reason=generic_info_request words=N`.
- La línea `[CAPTAIN][timing]` sigue siendo una por turno; los turnos de la
  puerta salen con `llm_ms=0 tools_calls=0 agent="clarification_gate"`.
  Filtrar por `agent` al calcular p50/p95 de LLM.

## Configuración

```ruby
a = Captain::Assistant.find(<id>)
a.update!(config: a.config.merge(
  'clarification_gate_enabled' => true,
  'clarification_message' => '¿Sobre qué producto o servicio te gustaría información?'
))
```

Ambas claves están permitidas en `assistants_controller`. UI pendiente.

## Complemento

PR aparte: umbral de distancia en `FaqLookupTool` (reutiliza
`CAPTAIN_PREFETCH_DISTANCE_THRESHOLD`) para que "No relevant FAQs found"
pueda ocurrir, y retoque del prompt para que, si la petición no nombra
producto ni tema, el asistente pregunte cuál antes de buscar.
