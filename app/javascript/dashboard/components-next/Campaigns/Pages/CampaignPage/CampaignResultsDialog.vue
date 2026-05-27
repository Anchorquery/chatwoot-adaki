<script setup>
import { computed, ref, watch, onMounted, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import CampaignsAPI from 'dashboard/api/campaigns';

const props = defineProps({
  campaign: { type: Object, default: null },
});

const emit = defineEmits(['close']);
const { t } = useI18n();

// ── state ────────────────────────────────────────────────────────────────────
const loading = ref(false);
const retrying = ref(false);
const exporting = ref(false);
const contacts = ref([]);
const meta = ref({ total: 0, page: 1, per_page: 25, total_pages: 1 });
const stats = ref({});
const activeFilter = ref('');
const searchQuery = ref('');
const currentPage = ref(1);
let searchTimer = null;
let pollTimer = null;

// ── computed ─────────────────────────────────────────────────────────────────
const isRunning = computed(() => props.campaign?.campaign_status === 'running');
const sentPct = computed(() => {
  const total = stats.value.total_contacts || 0;
  const sent = stats.value.sent_count || 0;
  return total > 0 ? Math.round((sent / total) * 100) : 0;
});

const durationLabel = computed(() => {
  const sec = stats.value.duration_seconds;
  if (!sec) return null;
  if (sec < 60) return `${sec}s`;
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return s > 0 ? `${m}m ${s}s` : `${m}m`;
});

// ── data fetching ─────────────────────────────────────────────────────────────
async function fetchResults() {
  if (!props.campaign) return;
  loading.value = true;
  try {
    const { data } = await CampaignsAPI.results(props.campaign.display_id, {
      page: currentPage.value,
      status: activeFilter.value,
      q: searchQuery.value,
    });
    contacts.value = data.contacts;
    meta.value = data.meta;
    stats.value = data.stats;
  } catch {
    // silent
  } finally {
    loading.value = false;
  }
}

function startPolling() {
  if (pollTimer) return;
  pollTimer = setInterval(() => {
    if (!isRunning.value) {
      stopPolling();
      return;
    }
    fetchResults();
  }, 5000);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

// ── search debounce ───────────────────────────────────────────────────────────
function onSearchInput(e) {
  clearTimeout(searchTimer);
  searchQuery.value = e.target.value;
  searchTimer = setTimeout(() => {
    currentPage.value = 1;
    fetchResults();
  }, 300);
}

function setFilter(f) {
  activeFilter.value = f;
  currentPage.value = 1;
  fetchResults();
}

function goPage(p) {
  currentPage.value = p;
  fetchResults();
}

// ── retry ─────────────────────────────────────────────────────────────────────
async function retryFailed() {
  if (!confirm(t('CAMPAIGN.RESULTS.RETRY_CONFIRM', { count: stats.value.failed_count }))) return;
  retrying.value = true;
  try {
    const { data } = await CampaignsAPI.retryFailed(props.campaign.display_id);
    alert(t('CAMPAIGN.RESULTS.RETRY_SUCCESS', { count: data.retry_count }));
    currentPage.value = 1;
    await fetchResults();
    startPolling();
  } catch {
    alert(t('CAMPAIGN.RESULTS.RETRY_ERROR'));
  } finally {
    retrying.value = false;
  }
}

// ── export CSV ────────────────────────────────────────────────────────────────
async function exportCSV() {
  if (exporting.value) return;
  exporting.value = true;
  try {
    const allContacts = [];
    let page = 1;
    let totalPages = 1;
    do {
      const { data } = await CampaignsAPI.results(props.campaign.display_id, { page, status: '', q: '' });
      allContacts.push(...data.contacts);
      totalPages = data.meta.total_pages;
      page++;
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
      .map(r => r.map(v => `"${String(v ?? '').replace(/"/g, '""')}"`).join(','))
      .join('\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    const title = (props.campaign?.title ?? 'resultados')
      .replace(/[^a-z0-9_-]/gi, '_')
      .toLowerCase();
    a.download = `${title}_resultados.csv`;
    a.click();
    URL.revokeObjectURL(url);
  } finally {
    exporting.value = false;
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────
function formatTs(ts) {
  if (!ts) return '—';
  return new Date(ts).toLocaleString();
}

function statusLabel(s) {
  const map = {
    sent: t('CAMPAIGN.RESULTS.STATUS_SENT'),
    failed: t('CAMPAIGN.RESULTS.STATUS_FAILED'),
    skipped: t('CAMPAIGN.RESULTS.STATUS_SKIPPED'),
    pending: t('CAMPAIGN.RESULTS.STATUS_PENDING'),
  };
  return map[s] || s;
}

function statusClass(s) {
  return {
    sent: 'text-n-teal-10 bg-n-teal-3',
    failed: 'text-n-ruby-10 bg-n-ruby-3',
    skipped: 'text-n-amber-10 bg-n-amber-3',
    pending: 'text-n-slate-10 bg-n-alpha-2',
  }[s] || 'text-n-slate-10 bg-n-alpha-2';
}

function conversationUrl(conversationId) {
  if (!conversationId) return null;
  return `/app/accounts/${props.campaign?.account_id}/conversations/${conversationId}`;
}

// ── lifecycle ─────────────────────────────────────────────────────────────────
onMounted(() => {
  fetchResults();
  if (isRunning.value) startPolling();
});

watch(isRunning, val => {
  if (val) startPolling();
  else stopPolling();
});

onUnmounted(() => {
  stopPolling();
  clearTimeout(searchTimer);
});
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    @click.self="emit('close')"
  >
    <div
      class="bg-n-solid-1 rounded-2xl shadow-xl w-full max-w-2xl mx-4 flex flex-col max-h-[90vh]"
    >
      <!-- Header -->
      <div class="flex items-center justify-between p-4 border-b border-n-weak">
        <div class="min-w-0 flex-1">
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ t('CAMPAIGN.RESULTS.TITLE') }}
          </h3>
          <p class="text-xs text-n-slate-10 mt-0.5 truncate">{{ campaign?.title }}</p>
        </div>
        <div class="flex items-center gap-2 ml-3 flex-shrink-0">
          <Button
            variant="faded"
            size="sm"
            color="slate"
            :icon="exporting ? 'i-lucide-loader-2' : 'i-lucide-download'"
            :label="t('CAMPAIGN.RESULTS.EXPORT')"
            :disabled="exporting"
            @click="exportCSV"
          />
          <Button
            v-if="(stats.failed_count || 0) > 0 && !isRunning"
            variant="faded"
            size="sm"
            color="ruby"
            icon="i-lucide-refresh-cw"
            :label="t('CAMPAIGN.RESULTS.RETRY_FAILED')"
            :disabled="retrying"
            @click="retryFailed"
          />
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-x"
            @click="emit('close')"
          />
        </div>
      </div>

      <div class="p-4 flex flex-col gap-4 overflow-y-auto">
        <!-- Stats row -->
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div class="rounded-xl bg-n-alpha-2 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-slate-12">{{ stats.total_contacts ?? 0 }}</span>
            <span class="text-xs text-n-slate-10">{{ t('CAMPAIGN.RESULTS.TOTAL') }}</span>
          </div>
          <div class="rounded-xl bg-n-teal-3 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-teal-11">{{ stats.sent_count ?? 0 }}</span>
            <span class="text-xs text-n-teal-10">{{ t('CAMPAIGN.RESULTS.SENT') }}</span>
          </div>
          <div class="rounded-xl bg-n-ruby-3 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-ruby-11">{{ stats.failed_count ?? 0 }}</span>
            <span class="text-xs text-n-ruby-10">{{ t('CAMPAIGN.RESULTS.FAILED') }}</span>
          </div>
          <div class="rounded-xl bg-n-alpha-2 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-slate-12">
              {{ stats.success_rate != null ? `${stats.success_rate}%` : '—' }}
            </span>
            <span class="text-xs text-n-slate-10">{{ t('CAMPAIGN.RESULTS.SUCCESS_RATE') }}</span>
          </div>
        </div>

        <!-- Progress bar -->
        <div>
          <div class="flex justify-between text-xs text-n-slate-10 mb-1">
            <span>{{ t('CAMPAIGN.RESULTS.PROGRESS') }}</span>
            <span>{{ sentPct }}%</span>
          </div>
          <div class="h-2 rounded-full bg-n-alpha-3 overflow-hidden">
            <div
              class="h-full rounded-full bg-n-teal-9 transition-all"
              :style="{ width: `${sentPct}%` }"
            />
          </div>
        </div>

        <!-- Timing info -->
        <div
          v-if="stats.started_at"
          class="flex flex-wrap gap-x-4 gap-y-1 text-xs text-n-slate-10"
        >
          <span>
            <span class="font-medium text-n-slate-11">{{ t('CAMPAIGN.RESULTS.STARTED_AT') }}:</span>
            {{ formatTs(stats.started_at) }}
          </span>
          <span v-if="stats.completed_at">
            <span class="font-medium text-n-slate-11">{{ t('CAMPAIGN.RESULTS.COMPLETED_AT') }}:</span>
            {{ formatTs(stats.completed_at) }}
          </span>
          <span v-if="durationLabel">
            <span class="font-medium text-n-slate-11">{{ t('CAMPAIGN.RESULTS.DURATION') }}:</span>
            {{ durationLabel }}
          </span>
          <span v-if="stats.throughput_per_minute">
            <span class="font-medium text-n-slate-11">{{ t('CAMPAIGN.RESULTS.THROUGHPUT') }}:</span>
            {{ stats.throughput_per_minute }} {{ t('CAMPAIGN.RESULTS.MSGS_PER_MIN') }}
          </span>
        </div>

        <!-- Search + filter -->
        <div class="flex flex-col sm:flex-row gap-2">
          <div class="relative flex-1">
            <span class="absolute left-3 top-1/2 -translate-y-1/2 i-lucide-search w-3.5 h-3.5 text-n-slate-9" />
            <input
              class="w-full pl-8 pr-3 py-1.5 text-xs rounded-lg bg-n-alpha-2 border border-n-weak text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:ring-1 focus:ring-n-teal-7"
              :placeholder="t('CAMPAIGN.RESULTS.SEARCH_PLACEHOLDER')"
              @input="onSearchInput"
            />
          </div>
          <div class="flex gap-1">
            <button
              v-for="f in [{ key: '', label: t('CAMPAIGN.RESULTS.FILTER_ALL') }, { key: 'sent', label: t('CAMPAIGN.RESULTS.FILTER_SENT') }, { key: 'failed', label: t('CAMPAIGN.RESULTS.FILTER_FAILED') }]"
              :key="f.key"
              class="text-xs px-3 py-1.5 rounded-lg border transition-colors"
              :class="activeFilter === f.key
                ? 'bg-n-teal-9 text-white border-n-teal-9'
                : 'bg-n-alpha-2 text-n-slate-10 border-n-weak hover:text-n-slate-12'"
              @click="setFilter(f.key)"
            >
              {{ f.label }}
            </button>
          </div>
        </div>

        <!-- Table -->
        <div class="flex flex-col gap-1 min-h-[80px]">
          <!-- Loading -->
          <div
            v-if="loading"
            class="flex items-center justify-center py-8 text-xs text-n-slate-10 gap-2"
          >
            <span class="i-lucide-loader-2 animate-spin w-4 h-4" />
            {{ t('CAMPAIGN.RESULTS.LOADING_CONTACTS') }}
          </div>

          <!-- Empty -->
          <div
            v-else-if="contacts.length === 0"
            class="text-center py-8 text-xs text-n-slate-10"
          >
            {{ t('CAMPAIGN.RESULTS.NO_RESULTS') }}
          </div>

          <!-- Rows -->
          <div
            v-else
            class="flex flex-col gap-1"
          >
            <div
              v-for="c in contacts"
              :key="c.id"
              class="rounded-lg bg-n-alpha-2 px-3 py-2 flex items-center gap-3"
            >
              <!-- Avatar -->
              <div
                class="w-7 h-7 rounded-full bg-n-alpha-3 flex-shrink-0 flex items-center justify-center text-xs font-medium text-n-slate-11 overflow-hidden"
              >
                <img v-if="c.avatar_url" :src="c.avatar_url" class="w-full h-full object-cover" alt="" />
                <span v-else>{{ (c.name || '?')[0].toUpperCase() }}</span>
              </div>

              <!-- Info -->
              <div class="flex-1 min-w-0 flex flex-col">
                <span class="text-xs font-medium text-n-slate-12 truncate">
                  {{ c.name || `#${c.id}` }}
                </span>
                <span class="text-xs text-n-slate-10 truncate">
                  {{ c.phone_number || c.email || `ID: ${c.id}` }}
                </span>
                <span
                  v-if="c.error"
                  class="text-xs text-n-ruby-9 truncate"
                  :title="c.error"
                >
                  {{ c.error }}
                </span>
              </div>

              <!-- Status badge -->
              <span
                class="text-xs px-2 py-0.5 rounded-full font-medium flex-shrink-0"
                :class="statusClass(c.status)"
              >
                {{ statusLabel(c.status) }}
              </span>

              <!-- Sent at -->
              <span class="text-xs text-n-slate-9 flex-shrink-0 hidden sm:block whitespace-nowrap">
                {{ formatTs(c.sent_at || c.failed_at || c.skipped_at) }}
              </span>

              <!-- Conversation link -->
              <a
                v-if="c.conversation_id"
                :href="conversationUrl(c.conversation_id)"
                target="_blank"
                class="i-lucide-external-link w-3.5 h-3.5 text-n-slate-9 hover:text-n-teal-9 flex-shrink-0"
                :title="t('CAMPAIGN.RESULTS.VIEW_CONVERSATION')"
              />
              <span v-else class="w-3.5 flex-shrink-0" />
            </div>
          </div>
        </div>

        <!-- Pagination -->
        <div
          v-if="meta.total_pages > 1"
          class="flex items-center justify-between text-xs text-n-slate-10"
        >
          <span>{{ meta.total }} {{ t('CAMPAIGN.RESULTS.TOTAL').toLowerCase() }}</span>
          <div class="flex gap-1 items-center">
            <button
              class="px-2 py-1 rounded bg-n-alpha-2 hover:bg-n-alpha-3 disabled:opacity-40"
              :disabled="currentPage <= 1"
              @click="goPage(currentPage - 1)"
            >
              ‹
            </button>
            <span class="px-2">{{ currentPage }} / {{ meta.total_pages }}</span>
            <button
              class="px-2 py-1 rounded bg-n-alpha-2 hover:bg-n-alpha-3 disabled:opacity-40"
              :disabled="currentPage >= meta.total_pages"
              @click="goPage(currentPage + 1)"
            >
              ›
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
