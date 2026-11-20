<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

import CampaignsAPI from 'dashboard/api/campaigns';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

// CampaignsPageRouteView no la cachea: cada visita carga la campaña de nuevo.
defineOptions({ name: 'CampaignResultsPage' });

const POLL_INTERVAL = 5000;
const NOT_ON_WHATSAPP = /not on WhatsApp/i;

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const campaign = ref(null);
const isLoadingCampaign = ref(true);
const loading = ref(false);
const retrying = ref(false);
const exporting = ref(false);
const duplicating = ref(false);
const contacts = ref([]);
const meta = ref({ total: 0, page: 1, per_page: 25, total_pages: 1 });
const stats = ref({});
const activeFilter = ref('');
const typeFilter = ref('');
const searchQuery = ref('');
const currentPage = ref(1);
const retryConfirmDialogRef = ref(null);
let searchTimer = null;
let pollTimer = null;

const campaignId = computed(() => route.params.campaignId);
const isRunning = computed(() => campaign.value?.campaign_status === 'running');
const isApiCampaign = computed(
  () => campaign.value?.inbox?.channel_type === INBOX_TYPES.API
);

// Solo los fallidos reintentables: a los omitidos no se les escribe, y los 463
// o los números sin WhatsApp fallarían igual.
const retryableCount = computed(
  () => stats.value.retryable_failed_count ?? stats.value.failed_count ?? 0
);
const notRetryableCount = computed(
  () => (stats.value.failed_count ?? 0) - retryableCount.value
);
// Los que no llegaron a procesarse: una campaña pausada o cortada a medias.
const pendingCount = computed(() => stats.value.pending_count ?? 0);
const sendPendingCount = computed(
  () => retryableCount.value + pendingCount.value
);

// Los omitidos no tenían conversación previa: solo se les escribe si la
// campaña ya permite contactos nuevos; si no, se vuelven a omitir.
const skippedCount = computed(() => stats.value.skipped_count ?? 0);
const allowsNewContacts = computed(() =>
  Boolean(campaign.value?.delivery_settings?.allow_new_contacts)
);

// "Enviar a pendientes": a fallidos y pendientes, solo a unos u otros, o a
// los omitidos. Se ofrece aunque la campaña haya terminado.
const sendScope = ref('all');
const sendScopes = computed(() =>
  [
    { key: 'all', count: sendPendingCount.value, label: 'SCOPE_ALL' },
    { key: 'failed', count: retryableCount.value, label: 'SCOPE_FAILED' },
    { key: 'pending', count: pendingCount.value, label: 'SCOPE_PENDING' },
    { key: 'skipped', count: skippedCount.value, label: 'SCOPE_SKIPPED' },
  ].filter(scope => scope.count > 0)
);
const canSendAgain = computed(() => sendScopes.value.length > 0);
const scopeCount = computed(
  () =>
    sendScopes.value.find(scope => scope.key === sendScope.value)?.count ?? 0
);

// Misma cuenta que Campaigns::ApiWebhookDispatchPlannerService: pausa entre
// mensajes, pausa larga entre tandas y tope por minuto. Es aproximado: no
// cuenta el horario comercial ni las esperas por sesión caída.
const etaSeconds = computed(() => {
  const n = scopeCount.value;
  if (n <= 1) return 0;
  const settings = campaign.value?.delivery_settings || {};
  const batchSize = Number(settings.batch_size) || 0;
  const perMessage = Number(settings.delay_between_messages_seconds) || 0;
  const perBatch = Number(settings.delay_between_batches_seconds) || 0;
  const perMinute = Number(settings.max_messages_per_minute) || 0;
  const gaps = n - 1;
  const batchGaps = batchSize > 0 ? Math.floor(gaps / batchSize) : 0;
  const paced = (gaps - batchGaps) * perMessage + batchGaps * perBatch;
  const capped = perMinute > 0 ? (gaps / perMinute) * 60 : 0;
  return Math.max(paced, capped);
});

const etaLabel = computed(() => {
  const minutes = Math.max(1, Math.round(etaSeconds.value / 60));
  if (minutes < 60)
    return t('CAMPAIGN.RESULTS.ETA_MINUTES', { count: minutes });
  return t('CAMPAIGN.RESULTS.ETA_HOURS', {
    hours: Math.floor(minutes / 60),
    minutes: minutes % 60,
  });
});

const etaDays = computed(() => {
  const daily = Number(campaign.value?.delivery_settings?.max_daily_messages);
  return daily > 0 ? Math.ceil(scopeCount.value / daily) : 0;
});

function openSendPending() {
  sendScope.value = sendScopes.value[0]?.key || 'all';
  retryConfirmDialogRef.value?.open();
}

const sentPct = computed(() => {
  const total = stats.value.total_contacts || 0;
  return total > 0
    ? Math.round(((stats.value.sent_count || 0) / total) * 100)
    : 0;
});

const durationLabel = computed(() => {
  const sec = stats.value.duration_seconds;
  if (!sec) return null;
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const parts = [];
  if (d) parts.push(`${d}d`);
  if (h) parts.push(`${h}h`);
  if (m && !d) parts.push(`${m}m`);
  if (!d && !h && s) parts.push(`${s}s`);
  return parts.join(' ') || '0s';
});

const statCards = computed(() => [
  {
    key: '',
    label: t('CAMPAIGN.RESULTS.TOTAL'),
    value: stats.value.total_contacts ?? 0,
    tone: 'bg-n-alpha-2 text-n-slate-12',
  },
  {
    key: 'sent',
    label: t('CAMPAIGN.RESULTS.SENT'),
    value: stats.value.sent_count ?? 0,
    tone: 'bg-n-teal-3 text-n-teal-11',
  },
  {
    key: 'failed',
    label: t('CAMPAIGN.RESULTS.FAILED'),
    value: stats.value.failed_count ?? 0,
    tone: 'bg-n-ruby-3 text-n-ruby-11',
  },
  {
    key: 'skipped',
    label: t('CAMPAIGN.RESULTS.SKIPPED'),
    value: stats.value.skipped_count ?? 0,
    tone: 'bg-n-amber-3 text-n-amber-11',
  },
  {
    key: 'pending',
    label: t('CAMPAIGN.RESULTS.PENDING_TOTAL'),
    value: stats.value.pending_count ?? 0,
    tone: 'bg-n-alpha-2 text-n-slate-12',
  },
]);

const filters = computed(() => [
  { key: '', label: t('CAMPAIGN.RESULTS.FILTER_ALL') },
  { key: 'sent', label: t('CAMPAIGN.RESULTS.FILTER_SENT') },
  { key: 'failed', label: t('CAMPAIGN.RESULTS.FILTER_FAILED') },
  { key: 'skipped', label: t('CAMPAIGN.RESULTS.FILTER_SKIPPED') },
  { key: 'pending', label: t('CAMPAIGN.RESULTS.FILTER_PENDING') },
]);

const listRouteName = computed(() => {
  const type = campaign.value?.inbox?.channel_type;
  if (type === INBOX_TYPES.WHATSAPP) return 'campaigns_whatsapp_index';
  if (type === INBOX_TYPES.SMS || type === INBOX_TYPES.TWILIO) {
    return 'campaigns_sms_index';
  }
  return 'campaigns_api_index';
});

// ── carga ────────────────────────────────────────────────────────────────────
async function loadCampaign() {
  try {
    const { data } = await CampaignsAPI.show(campaignId.value);
    campaign.value = data;
  } catch {
    useAlert(t('CAMPAIGN.RESULTS.LOAD_ERROR'));
    router.push({ name: 'campaigns_api_index', params: route.params });
  }
}

async function fetchResults() {
  loading.value = true;
  try {
    const { data } = await CampaignsAPI.results(campaignId.value, {
      page: currentPage.value,
      status: activeFilter.value,
      q: searchQuery.value,
      type: typeFilter.value,
    });
    contacts.value = data.contacts;
    meta.value = data.meta;
    stats.value = data.stats;
  } catch {
    // El siguiente refresco lo vuelve a intentar.
  } finally {
    loading.value = false;
  }
}

async function refreshAll() {
  await Promise.all([loadCampaign(), fetchResults()]);
}

function stopPolling() {
  clearInterval(pollTimer);
  pollTimer = null;
}

function startPolling() {
  if (pollTimer) return;
  pollTimer = setInterval(async () => {
    await refreshAll();
    if (!isRunning.value) stopPolling();
  }, POLL_INTERVAL);
}

// ── filtros ──────────────────────────────────────────────────────────────────
function onSearchInput(e) {
  clearTimeout(searchTimer);
  searchQuery.value = e.target.value;
  searchTimer = setTimeout(() => {
    currentPage.value = 1;
    fetchResults();
  }, 300);
}

// Solo se ofrece filtrar por tipo si la campaña mezcla contactos con grupos o
// canales.
const typeFilters = computed(() => {
  const counts = stats.value.type_counts || {};
  const types = [
    { key: 'contact', label: 'TYPE_CONTACT' },
    { key: 'group', label: 'TYPE_GROUP' },
    { key: 'channel', label: 'TYPE_CHANNEL' },
  ].filter(type => counts[type.key] > 0);
  if (types.length < 2) return [];
  return [{ key: '', label: 'FILTER_TYPE_ALL' }, ...types].map(type => ({
    ...type,
    count: type.key ? counts[type.key] : null,
  }));
});

function setTypeFilter(key) {
  typeFilter.value = key;
  currentPage.value = 1;
  fetchResults();
}

const recipientBadge = c => {
  if (c.recipient_type === 'group') return t('CAMPAIGN.RESULTS.BADGE_GROUP');
  if (c.recipient_type === 'channel')
    return t('CAMPAIGN.RESULTS.BADGE_CHANNEL');
  return '';
};

// Evolution guarda los grupos como "Nombre (GROUP)": en la lista sobra.
const recipientName = c =>
  c.recipient_type === 'group'
    ? (c.name || '').replace(/\s*\(GROUP\)$/, '')
    : c.name;

function setFilter(key) {
  activeFilter.value = key;
  currentPage.value = 1;
  fetchResults();
}

function goPage(page) {
  currentPage.value = page;
  fetchResults();
}

// ── acciones ─────────────────────────────────────────────────────────────────
function goBack() {
  router.push({ name: listRouteName.value, params: route.params });
}

function editCampaign() {
  router.push({
    name: 'campaigns_api_edit',
    params: { ...route.params, campaignId: campaignId.value },
  });
}

async function duplicateCampaign() {
  duplicating.value = true;
  try {
    const cloned = await store.dispatch('campaigns/clone', campaignId.value);
    router.push({
      name: 'campaigns_api_edit',
      params: { ...route.params, campaignId: cloned.id },
    });
  } catch {
    useAlert(t('CAMPAIGN.RESULTS.DUPLICATE_ERROR'));
  } finally {
    duplicating.value = false;
  }
}

async function confirmRetryFailed() {
  retrying.value = true;
  try {
    const { data } = await CampaignsAPI.retryFailed(
      campaignId.value,
      sendScope.value
    );
    useAlert(
      t('CAMPAIGN.RESULTS.SEND_PENDING_SUCCESS', { count: data.retry_count })
    );
    currentPage.value = 1;
    await refreshAll();
    startPolling();
  } catch {
    useAlert(t('CAMPAIGN.RESULTS.RETRY_ERROR'));
  } finally {
    retrying.value = false;
    retryConfirmDialogRef.value?.close();
  }
}

async function exportCSV() {
  if (exporting.value) return;
  exporting.value = true;
  try {
    const allContacts = [];
    let page = 1;
    let totalPages = 1;
    do {
      // Cada página depende del total_pages de la anterior.
      // eslint-disable-next-line no-await-in-loop
      const { data } = await CampaignsAPI.results(campaignId.value, { page });
      allContacts.push(...data.contacts);
      totalPages = data.meta.total_pages;
      page += 1;
    } while (page <= totalPages);

    const rows = [
      [
        t('CAMPAIGN.RESULTS.CONTACT_ID'),
        t('CAMPAIGN.RESULTS.CONTACT_NAME'),
        t('CAMPAIGN.RESULTS.CONTACT_PHONE'),
        t('CAMPAIGN.RESULTS.COL_STATUS'),
        t('CAMPAIGN.RESULTS.COL_SENT_AT'),
        t('CAMPAIGN.RESULTS.COL_ERROR'),
        'Conversation ID',
      ],
      ...allContacts.map(c => [
        c.id,
        c.name || '',
        c.phone_number || '',
        c.status,
        c.sent_at || c.failed_at || c.skipped_at || '',
        c.error || '',
        c.conversation_id || '',
      ]),
    ];
    const csv = rows
      .map(r =>
        r.map(v => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')
      )
      .join('\n');
    const blob = new Blob(['﻿' + csv], {
      type: 'text/csv;charset=utf-8;',
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    const title = (campaign.value?.title ?? 'resultados')
      .replace(/[^a-z0-9_-]/gi, '_')
      .toLowerCase();
    a.download = `${title}_resultados.csv`;
    a.click();
    URL.revokeObjectURL(url);
  } finally {
    exporting.value = false;
  }
}

// ── formato ──────────────────────────────────────────────────────────────────
function formatTs(ts) {
  if (!ts) return '—';
  const date = typeof ts === 'number' ? new Date(ts * 1000) : new Date(ts);
  return date.toLocaleString();
}

function errorLabel(error) {
  if (!error) return t('CAMPAIGN.RESULTS.REASON_UNKNOWN');
  if (NOT_ON_WHATSAPP.test(error)) {
    return t('CAMPAIGN.RESULTS.REASON_NOT_ON_WHATSAPP');
  }
  return error;
}

function statusLabel(status) {
  return (
    {
      sent: t('CAMPAIGN.RESULTS.STATUS_SENT'),
      failed: t('CAMPAIGN.RESULTS.STATUS_FAILED'),
      skipped: t('CAMPAIGN.RESULTS.STATUS_SKIPPED'),
      pending: t('CAMPAIGN.RESULTS.STATUS_PENDING'),
    }[status] || status
  );
}

function statusClass(status) {
  return (
    {
      sent: 'text-n-teal-10 bg-n-teal-3',
      failed: 'text-n-ruby-10 bg-n-ruby-3',
      skipped: 'text-n-amber-10 bg-n-amber-3',
    }[status] || 'text-n-slate-10 bg-n-alpha-2'
  );
}

function conversationRoute(conversationId) {
  return {
    name: 'inbox_conversation',
    params: {
      accountId: route.params.accountId,
      conversation_id: conversationId,
    },
  };
}

// ── ciclo de vida ────────────────────────────────────────────────────────────
onMounted(async () => {
  await refreshAll();
  isLoadingCampaign.value = false;
  if (isRunning.value) startPolling();
});

watch(isRunning, running => (running ? startPolling() : stopPolling()));

onUnmounted(() => {
  stopPolling();
  clearTimeout(searchTimer);
});
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header
      class="sticky top-0 z-10 px-4 sm:px-6 border-b border-n-weak bg-n-surface-1"
    >
      <div
        class="flex flex-wrap items-center justify-between w-full min-h-16 gap-3 py-3 mx-auto max-w-6xl"
      >
        <div class="flex items-center min-w-0 gap-2">
          <Button
            icon="i-lucide-arrow-left"
            variant="ghost"
            color="slate"
            size="sm"
            :aria-label="t('CAMPAIGN.RESULTS.BACK')"
            @click="goBack"
          />
          <div class="min-w-0">
            <p class="text-xs text-n-slate-10">
              {{ t('CAMPAIGN.RESULTS.TITLE') }}
            </p>
            <h1 class="truncate text-heading-2 text-n-slate-12">
              {{ campaign?.title }}
            </h1>
          </div>
          <span
            v-if="isRunning"
            class="flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full shrink-0 bg-n-teal-3 text-n-teal-10"
          >
            <span class="w-1.5 h-1.5 rounded-full bg-n-teal-9 animate-pulse" />
            {{ t('CAMPAIGN.RESULTS.RUNNING') }}
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <Button
            variant="ghost"
            color="slate"
            size="sm"
            icon="i-lucide-refresh-cw"
            :aria-label="t('CAMPAIGN.RESULTS.REFRESH')"
            :disabled="loading"
            @click="refreshAll"
          />
          <Button
            v-if="isApiCampaign"
            variant="faded"
            color="slate"
            size="sm"
            icon="i-lucide-pencil"
            :label="t('CAMPAIGN.RESULTS.EDIT')"
            @click="editCampaign"
          />
          <Button
            v-if="isApiCampaign"
            variant="faded"
            color="slate"
            size="sm"
            icon="i-lucide-copy"
            :label="t('CAMPAIGN.RESULTS.DUPLICATE')"
            :is-loading="duplicating"
            @click="duplicateCampaign"
          />
          <Button
            variant="faded"
            color="slate"
            size="sm"
            :icon="exporting ? 'i-lucide-loader-2' : 'i-lucide-download'"
            :label="t('CAMPAIGN.RESULTS.EXPORT')"
            :disabled="exporting"
            @click="exportCSV"
          />
          <Button
            v-if="!isRunning"
            variant="faded"
            :color="canSendAgain ? 'ruby' : 'slate'"
            size="sm"
            icon="i-lucide-send"
            :label="
              canSendAgain
                ? `${t('CAMPAIGN.RESULTS.SEND_PENDING')} (${sendPendingCount + skippedCount})`
                : t('CAMPAIGN.RESULTS.SEND_PENDING')
            "
            :disabled="retrying"
            @click="openSendPending"
          />
        </div>
      </div>
    </header>

    <Dialog
      ref="retryConfirmDialogRef"
      type="alert"
      :title="t('CAMPAIGN.RESULTS.SEND_PENDING_TITLE')"
      :description="t('CAMPAIGN.RESULTS.SEND_PENDING_CONFIRM')"
      :confirm-button-label="
        t('CAMPAIGN.RESULTS.SEND_NOW', { count: scopeCount })
      "
      :disable-confirm-button="scopeCount === 0"
      :is-loading="retrying"
      @confirm="confirmRetryFailed"
    >
      <div class="flex flex-col gap-2">
        <p v-if="!canSendAgain" class="mb-0 text-sm text-n-slate-11">
          {{ t('CAMPAIGN.RESULTS.NOTHING_TO_SEND') }}
          <template v-if="notRetryableCount > 0">
            {{
              t('CAMPAIGN.RESULTS.NOTHING_TO_SEND_NOT_RETRYABLE', {
                count: notRetryableCount,
              })
            }}
          </template>
        </p>
        <label
          v-for="scope in sendScopes"
          :key="scope.key"
          class="flex items-center gap-2 text-sm text-n-slate-12 cursor-pointer"
        >
          <input
            v-model="sendScope"
            type="radio"
            name="send-pending-scope"
            :value="scope.key"
          />
          {{ t(`CAMPAIGN.RESULTS.${scope.label}`, { count: scope.count }) }}
        </label>
        <p
          v-if="sendScope === 'skipped'"
          class="mb-0 text-xs"
          :class="allowsNewContacts ? 'text-n-slate-11' : 'text-n-amber-11'"
        >
          {{
            allowsNewContacts
              ? t('CAMPAIGN.RESULTS.SKIPPED_ALLOWED_HINT')
              : t('CAMPAIGN.RESULTS.SKIPPED_BLOCKED_HINT')
          }}
        </p>
        <p v-if="canSendAgain" class="mb-0 text-xs text-n-slate-11">
          {{ t('CAMPAIGN.RESULTS.ETA', { time: etaLabel }) }}
          <template v-if="etaDays > 1">
            {{ t('CAMPAIGN.RESULTS.ETA_DAYS', { days: etaDays }) }}
          </template>
        </p>
      </div>
    </Dialog>

    <main class="flex-1 min-h-0 px-4 sm:px-6 overflow-y-auto">
      <div
        v-if="isLoadingCampaign"
        class="flex items-center justify-center py-10 text-n-slate-11"
      >
        <Spinner />
      </div>

      <div v-else class="flex flex-col w-full gap-5 py-6 mx-auto max-w-6xl">
        <!-- Totales: cada tarjeta filtra la lista -->
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <button
            v-for="card in statCards"
            :key="card.key"
            class="flex flex-col items-start gap-1 p-3 text-left transition rounded-xl outline outline-1"
            :class="[
              card.tone,
              activeFilter === card.key
                ? 'outline-n-teal-8'
                : 'outline-transparent hover:outline-n-weak',
            ]"
            @click="setFilter(card.key)"
          >
            <span class="text-2xl font-semibold">{{ card.value }}</span>
            <span class="text-xs opacity-80">{{ card.label }}</span>
          </button>
          <div
            class="flex flex-col items-start gap-1 p-3 rounded-xl bg-n-alpha-2 text-n-slate-12"
          >
            <span class="text-2xl font-semibold">
              {{ stats.success_rate != null ? `${stats.success_rate}%` : '—' }}
            </span>
            <span class="text-xs opacity-80">
              {{ t('CAMPAIGN.RESULTS.SUCCESS_RATE') }}
            </span>
          </div>
        </div>

        <!-- Progreso y tiempos -->
        <div class="flex flex-col gap-2">
          <div class="flex justify-between text-xs text-n-slate-10">
            <span>{{ t('CAMPAIGN.RESULTS.PROGRESS') }}</span>
            <span>{{ sentPct }}%</span>
          </div>
          <div class="h-2 overflow-hidden rounded-full bg-n-alpha-3">
            <div
              class="h-full transition-all rounded-full bg-n-teal-9"
              :style="{ width: `${sentPct}%` }"
            />
          </div>
          <div
            v-if="stats.started_at"
            class="flex flex-wrap text-xs gap-x-4 gap-y-1 text-n-slate-10"
          >
            <span>
              <span class="font-medium text-n-slate-11">
                {{ t('CAMPAIGN.RESULTS.STARTED_AT') }}:
              </span>
              {{ formatTs(stats.started_at) }}
            </span>
            <span v-if="stats.completed_at">
              <span class="font-medium text-n-slate-11">
                {{ t('CAMPAIGN.RESULTS.COMPLETED_AT') }}:
              </span>
              {{ formatTs(stats.completed_at) }}
            </span>
            <span v-if="durationLabel">
              <span class="font-medium text-n-slate-11">
                {{ t('CAMPAIGN.RESULTS.DURATION') }}:
              </span>
              {{ durationLabel }}
            </span>
            <span v-if="stats.throughput_per_minute">
              <span class="font-medium text-n-slate-11">
                {{ t('CAMPAIGN.RESULTS.THROUGHPUT') }}:
              </span>
              {{ stats.throughput_per_minute }}
              {{ t('CAMPAIGN.RESULTS.MSGS_PER_MIN') }}
            </span>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-5 lg:grid-cols-3">
          <!-- Destinatarios -->
          <div class="flex flex-col min-w-0 gap-3 lg:col-span-2">
            <div class="flex flex-col gap-2 lg:flex-row lg:flex-wrap">
              <div class="relative flex-1 min-w-0 lg:min-w-[14rem]">
                <span
                  class="absolute w-3.5 h-3.5 -translate-y-1/2 left-3 top-1/2 i-lucide-search text-n-slate-9"
                />
                <input
                  class="w-full py-1.5 pr-3 text-sm border rounded-lg pl-8 bg-n-alpha-2 border-n-weak text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:ring-1 focus:ring-n-teal-7"
                  :placeholder="t('CAMPAIGN.RESULTS.SEARCH_PLACEHOLDER')"
                  @input="onSearchInput"
                />
              </div>
              <div class="flex flex-wrap gap-1">
                <button
                  v-for="f in filters"
                  :key="f.key"
                  class="px-3 py-1.5 text-xs border rounded-lg transition-colors"
                  :class="
                    activeFilter === f.key
                      ? 'bg-n-teal-9 text-white border-n-teal-9'
                      : 'bg-n-alpha-2 text-n-slate-10 border-n-weak hover:text-n-slate-12'
                  "
                  @click="setFilter(f.key)"
                >
                  {{ f.label }}
                </button>
              </div>
              <div v-if="typeFilters.length" class="flex flex-wrap gap-1">
                <button
                  v-for="type in typeFilters"
                  :key="type.key || 'all'"
                  class="px-3 py-1.5 text-xs border rounded-lg transition-colors"
                  :class="
                    typeFilter === type.key
                      ? 'bg-n-slate-12 text-n-solid-1 border-n-slate-12'
                      : 'bg-n-alpha-2 text-n-slate-10 border-n-weak hover:text-n-slate-12'
                  "
                  @click="setTypeFilter(type.key)"
                >
                  {{ t(`CAMPAIGN.RESULTS.${type.label}`) }}
                  <span v-if="type.count !== null" class="ml-0.5 opacity-70">
                    {{ type.count }}
                  </span>
                </button>
              </div>
            </div>

            <div
              v-if="loading && contacts.length === 0"
              class="flex items-center justify-center gap-2 py-8 text-xs text-n-slate-10"
            >
              <span class="w-4 h-4 i-lucide-loader-2 animate-spin" />
              {{ t('CAMPAIGN.RESULTS.LOADING_CONTACTS') }}
            </div>
            <div
              v-else-if="contacts.length === 0"
              class="py-8 text-xs text-center text-n-slate-10"
            >
              {{ t('CAMPAIGN.RESULTS.NO_RESULTS') }}
            </div>
            <ul v-else class="flex flex-col gap-1">
              <li
                v-for="c in contacts"
                :key="c.id"
                class="flex items-start gap-3 px-3 py-2.5 rounded-lg bg-n-alpha-2"
              >
                <div
                  class="flex items-center justify-center flex-shrink-0 overflow-hidden text-xs font-medium rounded-full w-8 h-8 bg-n-alpha-3 text-n-slate-11"
                >
                  <img
                    v-if="c.avatar_url"
                    :src="c.avatar_url"
                    class="object-cover w-full h-full"
                    alt=""
                  />
                  <span v-else>{{ (c.name || '?')[0].toUpperCase() }}</span>
                </div>
                <div class="flex flex-col flex-1 min-w-0">
                  <span
                    class="flex items-center gap-1.5 text-sm font-medium truncate text-n-slate-12"
                  >
                    <span class="truncate">
                      {{ recipientName(c) || `#${c.id}` }}
                    </span>
                    <span
                      v-if="recipientBadge(c)"
                      class="flex-shrink-0 px-1.5 py-0.5 text-[10px] font-medium rounded bg-n-alpha-3 text-n-slate-11"
                    >
                      {{ recipientBadge(c) }}
                    </span>
                  </span>
                  <span
                    v-if="!recipientBadge(c)"
                    class="text-xs truncate text-n-slate-10"
                  >
                    {{ c.phone_number || c.email || `ID: ${c.id}` }}
                  </span>
                  <span
                    v-if="c.status === 'failed' || c.error"
                    class="text-xs break-words text-n-ruby-10"
                  >
                    {{ errorLabel(c.error) }}
                  </span>
                  <!-- En móvil la fecha va aquí para dejar sitio al nombre. -->
                  <span class="text-xs text-n-slate-9 sm:hidden">
                    {{ formatTs(c.sent_at || c.failed_at || c.skipped_at) }}
                  </span>
                </div>
                <div class="flex flex-col items-end flex-shrink-0 gap-1">
                  <div
                    class="flex flex-col-reverse items-end gap-1 sm:flex-row sm:items-center"
                  >
                    <span
                      v-if="c.retryable === false"
                      class="px-2 py-0.5 text-xs rounded-full bg-n-alpha-3 text-n-slate-10 whitespace-nowrap"
                    >
                      {{ t('CAMPAIGN.RESULTS.NOT_RETRYABLE') }}
                    </span>
                    <span
                      class="px-2 py-0.5 text-xs font-medium rounded-full whitespace-nowrap"
                      :class="statusClass(c.status)"
                    >
                      {{ statusLabel(c.status) }}
                    </span>
                  </div>
                  <span
                    class="hidden text-xs text-n-slate-9 whitespace-nowrap sm:inline"
                  >
                    {{ formatTs(c.sent_at || c.failed_at || c.skipped_at) }}
                  </span>
                </div>
                <router-link
                  v-if="c.conversation_id"
                  :to="conversationRoute(c.conversation_id)"
                  class="flex-shrink-0 mt-1 i-lucide-message-square w-4 h-4 text-n-slate-9 hover:text-n-teal-9"
                  :title="t('CAMPAIGN.RESULTS.VIEW_CONVERSATION')"
                />
                <span v-else class="flex-shrink-0 w-4" />
              </li>
            </ul>

            <div
              v-if="meta.total_pages > 1"
              class="flex items-center justify-between text-xs text-n-slate-10"
            >
              <span>
                {{ meta.total }} {{ t('CAMPAIGN.RESULTS.TOTAL').toLowerCase() }}
              </span>
              <div class="flex items-center gap-1">
                <button
                  class="px-2 py-1 rounded bg-n-alpha-2 hover:bg-n-alpha-3 disabled:opacity-40"
                  :disabled="currentPage <= 1"
                  @click="goPage(currentPage - 1)"
                >
                  <span class="block w-3 h-3 i-lucide-chevron-left" />
                </button>
                <span class="px-2">
                  {{ currentPage }} / {{ meta.total_pages }}
                </span>
                <button
                  class="px-2 py-1 rounded bg-n-alpha-2 hover:bg-n-alpha-3 disabled:opacity-40"
                  :disabled="currentPage >= meta.total_pages"
                  @click="goPage(currentPage + 1)"
                >
                  <span class="block w-3 h-3 i-lucide-chevron-right" />
                </button>
              </div>
            </div>
          </div>

          <!-- Lateral: motivos de fallo y datos de la campaña -->
          <aside class="flex flex-col gap-4">
            <div
              v-if="stats.failure_reasons?.length"
              class="flex flex-col gap-2 p-4 rounded-xl bg-n-alpha-2"
            >
              <h2 class="text-sm font-medium text-n-slate-12">
                {{ t('CAMPAIGN.RESULTS.FAILURE_REASONS') }}
              </h2>
              <ul class="flex flex-col gap-2">
                <li
                  v-for="reason in stats.failure_reasons"
                  :key="reason.error || 'unknown'"
                  class="flex items-start justify-between gap-2 text-xs"
                >
                  <span class="min-w-0 break-words text-n-slate-11">
                    {{ errorLabel(reason.error) }}
                    <span v-if="!reason.retryable" class="block text-n-slate-9">
                      {{ t('CAMPAIGN.RESULTS.NOT_RETRYABLE') }}
                    </span>
                  </span>
                  <span class="font-semibold text-n-ruby-10 shrink-0">
                    {{ reason.count }}
                  </span>
                </li>
              </ul>
              <p
                v-if="notRetryableCount > 0"
                class="pt-2 mt-1 text-xs border-t border-n-weak text-n-slate-10"
              >
                {{
                  t('CAMPAIGN.RESULTS.NOT_RETRYABLE_HINT', {
                    count: notRetryableCount,
                  })
                }}
              </p>
            </div>

            <div
              class="flex flex-col gap-3 p-4 text-xs rounded-xl bg-n-alpha-2"
            >
              <h2 class="text-sm font-medium text-n-slate-12">
                {{ t('CAMPAIGN.RESULTS.DETAILS') }}
              </h2>
              <div v-if="campaign?.inbox?.name">
                <p class="text-n-slate-10">{{ t('CAMPAIGN.RESULTS.INBOX') }}</p>
                <p class="text-n-slate-12">{{ campaign.inbox.name }}</p>
              </div>
              <div v-if="campaign?.scheduled_at">
                <p class="text-n-slate-10">
                  {{ t('CAMPAIGN.RESULTS.SCHEDULED_AT') }}
                </p>
                <p class="text-n-slate-12">
                  {{ formatTs(campaign.scheduled_at) }}
                </p>
              </div>
              <div v-if="campaign?.message">
                <p class="text-n-slate-10">
                  {{ t('CAMPAIGN.RESULTS.MESSAGE') }}
                </p>
                <p
                  class="whitespace-pre-wrap break-words text-n-slate-12 max-h-60 overflow-y-auto"
                >
                  {{ campaign.message }}
                </p>
              </div>
              <div v-if="campaign?.attachments?.length">
                <p class="text-n-slate-10">
                  {{ t('CAMPAIGN.RESULTS.ATTACHMENTS') }}
                </p>
                <p
                  v-for="file in campaign.attachments"
                  :key="file.id"
                  class="truncate text-n-slate-12"
                >
                  {{ file.filename }}
                </p>
              </div>
            </div>
          </aside>
        </div>
      </div>
    </main>
  </section>
</template>
