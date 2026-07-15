# Detección de Grupos/Canales WhatsApp — tradeoff conocido del filtro de sidebar

Tres consumidores distintos necesitan saber "¿esta conversación es un grupo o
un canal de WhatsApp?". Solo dos de los tres usan la misma lógica. Este doc
explica el gap, por qué existe, su impacto real, y cómo cerrarlo si hace falta.

## Los tres consumidores

| Consumidor | Archivo | Lógica que usa |
|---|---|---|
| Badge en lista de conversaciones | [app/models/conversation.rb:209-254](app/models/conversation.rb:209) (`group?`/`whatsapp_channel?`) vía [app/views/api/v1/conversations/partials/_conversation.json.jbuilder:62-63](app/views/api/v1/conversations/partials/_conversation.json.jbuilder:62) y [app/presenters/conversations/event_data_presenter.rb](app/presenters/conversations/event_data_presenter.rb) | Heurístico Ruby **completo** |
| Audiencias Captain (routing de bot) | [enterprise/app/models/captain_inbox_audience.rb](enterprise/app/models/captain_inbox_audience.rb) vía `conversation.group_jid`/`whatsapp_channel_jid` | Heurístico Ruby **completo** |
| Filtro "Solo grupos/canales" del sidebar | [app/finders/conversation_finder.rb:187-202](app/finders/conversation_finder.rb:187) (`filter_by_chat_kind`) | **Solo** `contact_inboxes.source_id LIKE` |

## Qué mira el heurístico "completo" (Ruby) y qué NO mira el filtro SQL

`Conversation#group?`/`#whatsapp_channel?` ([app/models/conversation.rb:209](app/models/conversation.rb:209)) escanea, en este orden:

1. `contact_inbox.source_id` — con sufijo `@g.us` / `@newsletter`.
2. `contact.identifier`, `contact.phone_number`.
3. `additional_attributes` de la conversación Y del contacto, recorridos
   recursivamente (`flatten_attribute_values`), buscando el sufijo en
   cualquier valor anidado.
4. Markers explícitos (`chat_type`/`type` conteniendo "group"/"newsletter",
   `group_id`/`groupId`, `is_group`/`isGroup`) en esos mismos jsonb.
5. (Solo para grupo) fallback estructural: JID sin sufijo pero con forma de
   grupo (≥15 dígitos, o `<digitos>-<digitos>`).

El filtro SQL del sidebar (`ConversationFinder#filter_by_chat_kind`) **solo**
hace `contact_inboxes.source_id LIKE '%@g.us'` / `'%@newsletter'` — un JOIN +
LIKE, nada más. No toca `additional_attributes`, no toca `contact.identifier`,
no replica el fallback estructural.

## Por qué existe el gap (no es un descuido)

Replicar el heurístico completo en SQL puro no es viable con una sola
condición: requeriría escanear jsonb recursivamente vía `-&gt;&gt;`/`jsonb_path`
contra múltiples columnas de dos tablas distintas (`conversations` y
`contacts`), lo cual deja de ser "un filtro", pasa a ser una query compleja
con costo real en cada carga de sidebar. La alternativa correcta de raíz es
**materializar** `group_jid`/`whatsapp_channel_jid` como columnas reales
(ver sección "Cómo cerrarlo" abajo) — eso sí es indexable y baratísimo de
filtrar. Implementar esa migración no era parte del alcance pedido en su
momento, así que se documentó el límite en el propio código
([app/finders/conversation_finder.rb:17-22](app/finders/conversation_finder.rb:17)) en vez de inventar una
aproximación SQL a medias que igual quedaría incompleta.

## Impacto real esperado (bridge Evolution API)

Bajo. `contact_inbox.source_id` es el **primer** campo que el heurístico Ruby
chequea, y es el campo que Evolution API llena con el JID real al crear el
`contact_inbox` — es justo el mecanismo que ya hacía funcionar la detección de
grupos antes de este feature. El fallback a `additional_attributes` existe
para bridges que no garantizan eso (mencionado en el propio código como caso
de Telegram y similares), no para el flujo normal de Evolution API.

**Lo que NO se rompe si el gap se dispara:** badge (sigue correcto), routing
de Captain (sigue correcto), campañas (mecanismo aparte, no afectado). Lo
único que puede fallar es que el filtro "Solo canales"/"Solo grupos" del
sidebar no muestre una conversación puntual que el badge sí marca — un typo
de UX, no pérdida ni corrupción de datos.

## Cómo verificar el impacto real con datos de producción

```ruby
# Rails console — compara cuántas conversaciones matchea el heurístico Ruby
# completo (group?) vs cuántas matchea el filtro SQL actual (source_id LIKE).
account = Account.find(ID)

all_group_by_ruby = account.conversations.select(&:group?)
all_group_by_sql  = account.conversations.joins(:contact_inbox)
                            .where('contact_inboxes.source_id LIKE ?', '%@g.us')

missing = all_group_by_ruby.map(&:id) - all_group_by_sql.pluck(:id)
puts "Conversaciones marcadas como grupo por Ruby pero invisibles al filtro SQL: #{missing.size}"
puts missing.inspect
```

Repetir con `whatsapp_channel?` / `'%@newsletter'` para canales. Si `missing`
sale vacío (o casi) en tu cuenta real, el gap es puramente teórico para tu
setup y no hace falta tocar nada.

## Cómo cerrarlo de raíz (si `missing` no sale vacío)

1. Migración: agregar columnas reales `conversations.whatsapp_group_jid` y
   `conversations.whatsapp_channel_jid` (string, indexadas).
2. Backfill: correr `Conversation#group_jid`/`#whatsapp_channel_jid` (el
   heurístico Ruby completo, ya existente) sobre todas las conversaciones
   existentes y persistir el resultado en las columnas nuevas.
3. Escribir esas columnas en el momento en que se crea/actualiza el
   `contact_inbox` o llegan nuevos `additional_attributes` (callback o
   servicio dedicado), para que se mantengan sincronizadas hacia adelante.
4. `ConversationFinder#filter_by_chat_kind` pasa a hacer
   `where(whatsapp_group_jid: ...)`/`where.not(whatsapp_channel_jid: nil)`
   directo sobre la columna — sin JOIN, sin LIKE, indexado.
5. Opcional: una vez las columnas existen, `Conversation#group?`/
   `#whatsapp_channel?` podrían simplificarse para leer la columna en vez de
   recomputar el heurístico en cada llamada (cierra también el tradeoff de
   performance documentado en [app/models/conversation.rb:230-236](app/models/conversation.rb:230)).

Esto es un cambio de arquitectura razonable (1 migración + 1 job de backfill +
tocar 3-4 call sites), no una reescritura — pero es más que un fix de una
línea, por eso quedó fuera del alcance de la ronda anterior.
