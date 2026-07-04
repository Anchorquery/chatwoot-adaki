# 2026-07-04 — Gaps UX de Campaigns/Captain + fix de seguridad OAuth

Continuación de la sesión de estabilización de Captain multiprovider y deuda de
CI. Cuatro gaps de UX frontend flaggeados explícitamente + una auditoría de
Super Admin/OAuth que encontró un bug de seguridad real.

## 1. `@close` muerto en páginas de Campaign

**Commit:** `2e8f8c0`

`CampaignLayout.vue` solo emite `@click` (el botón de "nueva campaña"), nunca
`@close`. Las 4 páginas de campañas (`APICampaignsPage.vue`,
`LiveChatCampaignsPage.vue`, `SMSCampaignsPage.vue`,
`WhatsAppCampaignsPage.vue`) tenían `@close="toggleXCampaignDialog(false)"`
en el uso de `<CampaignLayout>` — atributo nativo inerte, sin efecto. Eliminado.

## 2. Placeholder ignorado en `AddNewRulesDialog.vue` (Captain guardrails/guidelines)

**Commit:** `2e8f8c0`

Bug más grave de lo reportado inicialmente. El componente referencia las keys
`CAPTAIN.ASSISTANTS.GUARDRAILS.ADD.NEW.FORM.{TITLE,DESCRIPTION,INSTRUCTION}.*`
para los campos de Título/Descripción/Instrucción, pero ese namespace `FORM`
**no existía** en ninguno de los dos locales — solo existía el equivalente bajo
`SCENARIOS.ADD.NEW.FORM`.

vue-i18n no tiene fallback configurado (`entrypoints/dashboard.js`, sin
`missingWarn`/handler custom), así que cada uso de este diálogo — tanto en
`guardrails/Index.vue` como en `guidelines/Index.vue` — renderizaba el string
de la key cruda en vez de un label. Bug visible en todo el flujo de creación
de guardrails/guidelines.

**Fix:** agregado el objeto `FORM` faltante en
`app/javascript/dashboard/i18n/locale/{en,es}/integrations.json` bajo
`GUARDRAILS.ADD.NEW`.

## 3. Auto-aprobación de campañas sin bloqueo en frontend

**Commit:** `987bd00`

Backend (`Adaki::CampaignApproval#approver_distinct_from_requester`) ya
rechaza `approved_by == requested_by`, pero
`app/javascript/dashboard/routes/dashboard/settings/adaki/approvals/Index.vue`
dejaba a cualquier usuario abrir el modal de aprobar/rechazar y disparar el
submit contra su propia solicitud — resultando en un error genérico tras el
intento en vez de prevenir la acción antes.

**Fix:** guard `isOwnRequest(campaign)` comparando `currentUser.id` vs
`campaign.sender.id`; deshabilita ambos botones (Approve/Reject) con tooltip
explicando el motivo (`ADAKI.APPROVALS.CANNOT_SELF_APPROVE`).

## 4. `confirm`/`alert` nativos en `CampaignResultsDialog.vue`

**Commit:** `ff7157d`

`retryFailed()` usaba `window.confirm`/`window.alert` nativos (marcado con
TODO desde antes). Reemplazado por:

- `Dialog` (`components-next/dialog/Dialog.vue`, `type="alert"`) para la
  confirmación — mismo patrón que `ConfirmDeleteCampaignDialog.vue` en la
  misma carpeta.
- `useAlert` para el toast de resultado (éxito/error), consistente con el
  resto de la UI.

Nuevas keys: `CAMPAIGN.RESULTS.RETRY_CONFIRM_TITLE` (en/es).

## 5. Seguridad: CSRF vía `provider_ignores_state: true` en Google OAuth

**Commit:** `809b1ec`

Encontrado en auditoría del "resto del universo CE" (Super Admin + OAuth/omniauth)
no cubierto por la limpieza de deuda anterior.

**Bug:** `config/initializers/omniauth.rb` deshabilitaba la validación del
`state` param en el callback de Google OAuth2
(`provider_ignores_state: true`). Sin esa validación, un atacante puede:

1. Iniciar su propio flujo OAuth con Google (login normal, como sí mismo).
2. Capturar la URL de callback que Google le devuelve (con su propio código
   de autorización de un solo uso).
3. Enviarle esa URL a la víctima (login-CSRF clásico).
4. La víctima, al visitarla, queda autenticada en la sesión/cuenta del
   atacante sin saberlo — puede terminar ingresando datos sensibles en una
   cuenta que no es la suya.

`omniauth-rails_csrf_protection` (ya en el Gemfile) protege la fase de
*request* (`/auth/google_oauth2`, POST con authenticity token) pero **no** la
fase de *callback* (GET, viene de Google) — el `state` param es la única
defensa ahí.

**Fix:** se quitó `provider_ignores_state: true`. Session store es
`cookie_store` con `same_site: :lax`
([config/initializers/session_store.rb](../../config/initializers/session_store.rb)),
que sí persiste la cookie de sesión (y por tanto el `state` guardado) en el
redirect top-level que hace Google de vuelta a la app — no requiere cambios
adicionales para que la validación funcione.

Verificado con `spec/controllers/devise/omniauth_callbacks_controller_spec.rb`
(8 examples, 0 failures) — el spec usa `OmniAuth.config.test_mode = true`, que
mockea el hash de auth y no pasa por la validación real de `state`, así que no
se ve afectado por el cambio.

**Fix adicional (mismo commit):** guard temprano en `omniauth_success` si el
provider no devuelve `email` — antes lanzaba una excepción sin manejar (500);
ahora redirige con `error: 'no-account-found'`.

### Descartado tras verificación (no eran bugs reales)

- **SAML email-based account linking** (`enterprise/app/builders/saml_user_builder.rb`):
  el builder solo corre después de que `omniauth-saml` valida la firma de la
  aserción contra el IdP *configurado por esa cuenta* — spoofear un email
  requeriría comprometer ese IdP ya confiado, que es el modelo de confianza
  estándar de cualquier SSO SAML. No es un bug de este código.
- **`SuperAdmin::AccountsController#destroy`**: ya protegido por
  `authenticate_super_admin!`; el `Account.find(params[:id])` es el patrón
  normal de Administrate, no hay bypass de autorización.
- **"Cuenta duplicada con email vacío" vía OAuth**: descartado — `User`
  valida `email presence: true`, así que un email nil no corrompe datos (en
  el peor caso, antes del fix de este mismo commit, lanzaba una excepción sin
  manejar).

## Pendiente (no investigado en esta sesión)

- Edge case de baja severidad en `enterprise/app/builders/saml_user_builder.rb#create_user`:
  si el IdP SAML configurado no manda el atributo `email` (aserción
  incompleta/mal mapeada), `auth_attribute('email').split('@')` lanza
  `NoMethodError` sin manejar. Requeriría un IdP de cliente mal configurado
  para disparar — bajo impacto, no se tocó por falta de cobertura de specs
  dedicada en código enterprise que afecta clientes con SSO activo.
