-- ============================================================
-- Diagnóstico Captain: "se pega y siempre manda al agente"
-- Ejecutar contra la BD de producción de Chatwoot (solo lectura).
-- Cada bloque es independiente. psql: \x on para lectura vertical.
-- ============================================================

-- ------------------------------------------------------------
-- 1. CAPA 1 — Límites de plan (InstallationConfig)
--    Si CAPTAIN_CLOUD_PLAN_LIMITS tiene JSON y la cuenta no tiene
--    plan_name que matchee => límite 0 => handoff en CADA mensaje
--    con el texto "Transferring to another agent for further assistance."
-- ------------------------------------------------------------
SELECT name, serialized_value
FROM installation_configs
WHERE name IN ('CAPTAIN_CLOUD_PLAN_LIMITS');

SELECT id,
       name,
       custom_attributes->>'plan_name'               AS plan_name,
       custom_attributes->>'captain_responses_usage' AS captain_responses_usage,
       custom_attributes->>'captain_documents_usage' AS captain_documents_usage,
       limits,
       adaki_captain_monthly_limit
FROM accounts
ORDER BY id;

-- ------------------------------------------------------------
-- 2. CAPA 2 — Límite mensual Adaki (solo aplica a ruta V1)
-- ------------------------------------------------------------
SELECT account_id, period, request_count, input_tokens, output_tokens
FROM adaki_captain_usages
WHERE period = date_trunc('month', now())
ORDER BY account_id;

-- ------------------------------------------------------------
-- 3. Features por cuenta (V2 vs V1, clasificador)
--    captain_integration_v2 ON  => ruta V2 (AgentRunnerService + HandoffTool)
--    captain_v1_action_classifier ON => clasificador extra que puede forzar handoff
-- ------------------------------------------------------------
SELECT id, name, feature_flags,
       (feature_flags::bit(64) ) AS flags_bits
FROM accounts;
-- Si prefieres nombres legibles, en rails console:
--   Account.find(ID).enabled_features

-- ------------------------------------------------------------
-- 4. Asistentes Captain y su config
--    Claves críticas en config:
--      autopilot_enabled  => si false: el bot NO se agenda (silencio) o gate
--      handoff_message    => texto que ve el cliente cuando hay handoff V1/error
--      temperature, instructions, feature_*
-- ------------------------------------------------------------
SELECT id, account_id, name, description,
       config,
       response_guidelines, guardrails,
       created_at, updated_at
FROM captain_assistants
ORDER BY account_id, id;

-- ------------------------------------------------------------
-- 5. Vínculo inbox <-> assistant + settings de takeover
-- ------------------------------------------------------------
SELECT ci.id, ci.inbox_id, i.name AS inbox_name, i.channel_type,
       ci.captain_assistant_id, ca.name AS assistant_name,
       ci.settings
FROM captain_inboxes ci
JOIN inboxes i  ON i.id = ci.inbox_id
JOIN captain_assistants ca ON ca.id = ci.captain_assistant_id
ORDER BY ci.inbox_id;

-- ------------------------------------------------------------
-- 6. Audiencias (grupos WhatsApp / labels -> assistant específico)
--    Sin audiencia que matchee y sin default => silencio.
-- ------------------------------------------------------------
SELECT * FROM captain_inbox_audiences ORDER BY inbox_id, position;

-- ------------------------------------------------------------
-- 7. Credenciales de IA por cuenta (Platform) — sin exponer secretos
-- ------------------------------------------------------------
SELECT id, account_id, provider, enabled, metadata, created_at, updated_at
FROM platform_credentials
ORDER BY account_id;
-- (si la tabla se llama distinto: \dt *credential*)

-- ------------------------------------------------------------
-- 8. EVIDENCIA — ¿qué handoff está ocurriendo realmente?
--    Distingue la causa por el TEXTO del mensaje de handoff:
--    a) 'Transferring to another agent for further assistance.'
--         => gate de cuota/autopilot en HookExecutionService (config)
--    b) config['handoff_message'] del assistant o i18n default
--         => handoff desde ResponseBuilderJob (error LLM, límite Adaki,
--            token conversation_handoff o clasificador)
--    c) nota privada del assistant con la razón
--         => HandoffTool V2 (el LLM decidió el handoff "legítimamente")
-- ------------------------------------------------------------
-- Últimos 100 mensajes salientes de bots (senders AgentBot/CaptainAssistant):
SELECT m.id, m.conversation_id, c.display_id, m.created_at,
       m.sender_type, m.private, left(m.content, 160) AS content
FROM messages m
JOIN conversations c ON c.id = m.conversation_id
WHERE m.sender_type IN ('CaptainAssistant', 'AgentBot')
ORDER BY m.created_at DESC
LIMIT 100;

-- Mensajes de handoff del gate de cuota (texto hardcodeado, sin sender):
SELECT m.id, m.conversation_id, m.created_at, left(m.content, 120)
FROM messages m
WHERE m.content LIKE 'Transferring to another agent%'
ORDER BY m.created_at DESC
LIMIT 50;

-- Notas privadas del HandoffTool (razón del handoff V2):
SELECT m.id, m.conversation_id, m.created_at, left(m.content, 200) AS reason
FROM messages m
WHERE m.private = true
  AND m.sender_type = 'CaptainAssistant'
ORDER BY m.created_at DESC
LIMIT 50;

-- ------------------------------------------------------------
-- 9. Conversaciones: proporción bot -> open (handoff) reciente
-- ------------------------------------------------------------
SELECT c.status, count(*)
FROM conversations c
WHERE c.updated_at > now() - interval '7 days'
GROUP BY c.status;

-- ------------------------------------------------------------
-- 10. Auditoría Adaki de invocaciones Captain (tokens, feature)
-- ------------------------------------------------------------
SELECT created_at, account_id, action, payload
FROM adaki_audit_log_entries
WHERE action LIKE 'captain.%'
ORDER BY created_at DESC
LIMIT 50;
