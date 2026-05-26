<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  campaign: { type: Object, default: null },
});

const emit = defineEmits(['close']);
const { t } = useI18n();

const activeTab = ref('sent');

const ds = computed(() => props.campaign?.delivery_state || {});
const total = computed(
  () =>
    ds.value.contact_ids?.length ??
    (ds.value.sent_count ?? 0) + (ds.value.failed_count ?? 0)
);
const sent = computed(() => ds.value.sent_count ?? 0);
const failed = computed(() => ds.value.failed_count ?? 0);
const errors = computed(() => ds.value.errors ?? []);
const sentPct = computed(() =>
  total.value > 0 ? Math.round((sent.value / total.value) * 100) : 0
);

const failedIds = computed(() => new Set(errors.value.map(e => String(e.contact_id))));
const sentContactIds = computed(() =>
  (ds.value.contact_ids ?? []).filter(id => !failedIds.value.has(String(id)))
);

const formatTs = ts => {
  if (!ts) return '';
  return new Date(ts).toLocaleString();
};

const exportCSV = () => {
  const rows = [
    [t('CAMPAIGN.RESULTS.CONTACT_ID'), 'Estado', 'Error', 'Fecha'],
  ];
  sentContactIds.value.forEach(id => {
    rows.push([id, 'enviado', '', '']);
  });
  errors.value.forEach(err => {
    rows.push([err.contact_id, 'fallido', err.message ?? '', formatTs(err.timestamp)]);
  });

  const csv = rows.map(r => r.map(v => `"${String(v).replace(/"/g, '""')}"`).join(',')).join('\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  const title = (props.campaign?.title ?? t('CAMPAIGN.RESULTS.EXPORT_FILENAME'))
    .replace(/[^a-z0-9_\-]/gi, '_')
    .toLowerCase();
  a.download = `${title}_resultados.csv`;
  a.click();
  URL.revokeObjectURL(url);
};
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    @click.self="emit('close')"
  >
    <div
      class="bg-n-solid-1 rounded-2xl shadow-xl w-full max-w-lg mx-4 flex flex-col max-h-[85vh]"
    >
      <!-- Header -->
      <div class="flex items-center justify-between p-4 border-b border-n-weak">
        <div class="min-w-0 flex-1">
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ t('CAMPAIGN.RESULTS.TITLE') }}
          </h3>
          <p class="text-xs text-n-slate-10 mt-0.5 truncate">
            {{ campaign?.title }}
          </p>
        </div>
        <div class="flex items-center gap-2 ml-3 flex-shrink-0">
          <Button
            variant="faded"
            size="sm"
            color="slate"
            icon="i-lucide-download"
            :label="t('CAMPAIGN.RESULTS.EXPORT')"
            @click="exportCSV"
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

      <!-- Stats -->
      <div class="p-4 flex flex-col gap-4 overflow-y-auto">
        <div class="grid grid-cols-3 gap-3">
          <div class="rounded-xl bg-n-alpha-2 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-slate-12">{{ total }}</span>
            <span class="text-xs text-n-slate-10">{{ t('CAMPAIGN.RESULTS.TOTAL') }}</span>
          </div>
          <div class="rounded-xl bg-n-teal-3 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-teal-11">{{ sent }}</span>
            <span class="text-xs text-n-teal-10">{{ t('CAMPAIGN.RESULTS.SENT') }}</span>
          </div>
          <div class="rounded-xl bg-n-ruby-3 p-3 flex flex-col items-center gap-1">
            <span class="text-2xl font-bold text-n-ruby-11">{{ failed }}</span>
            <span class="text-xs text-n-ruby-10">{{ t('CAMPAIGN.RESULTS.FAILED') }}</span>
          </div>
        </div>

        <!-- Progress -->
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

        <!-- Tabs -->
        <div
          v-if="sentContactIds.length || errors.length"
          class="flex flex-col gap-3"
        >
          <div class="flex gap-1 border-b border-n-weak">
            <button
              class="text-xs font-medium px-3 py-1.5 border-b-2 transition-colors"
              :class="activeTab === 'sent'
                ? 'border-n-teal-9 text-n-teal-11'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-12'"
              @click="activeTab = 'sent'"
            >
              {{ t('CAMPAIGN.RESULTS.SENT_CONTACTS') }} ({{ sentContactIds.length }})
            </button>
            <button
              v-if="errors.length"
              class="text-xs font-medium px-3 py-1.5 border-b-2 transition-colors"
              :class="activeTab === 'errors'
                ? 'border-n-ruby-9 text-n-ruby-11'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-12'"
              @click="activeTab = 'errors'"
            >
              {{ t('CAMPAIGN.RESULTS.ERRORS_TITLE') }} ({{ errors.length }})
            </button>
          </div>

          <!-- Sent contacts list -->
          <div
            v-if="activeTab === 'sent'"
            class="flex flex-col gap-1 max-h-56 overflow-y-auto"
          >
            <div v-if="sentContactIds.length === 0" class="text-center py-4 text-sm text-n-slate-10">
              —
            </div>
            <div
              v-for="contactId in sentContactIds"
              :key="contactId"
              class="rounded-lg bg-n-alpha-2 px-3 py-2 flex items-center justify-between"
            >
              <span class="text-xs text-n-slate-11">
                {{ t('CAMPAIGN.RESULTS.CONTACT_ID') }}: <span class="font-medium text-n-slate-12">{{ contactId }}</span>
              </span>
              <span class="i-lucide-check text-n-teal-9 w-3.5 h-3.5 flex-shrink-0" />
            </div>
          </div>

          <!-- Errors list -->
          <div
            v-if="activeTab === 'errors'"
            class="flex flex-col gap-1 max-h-56 overflow-y-auto"
          >
            <div
              v-for="(err, i) in errors"
              :key="i"
              class="rounded-lg bg-n-ruby-3 px-3 py-2 flex flex-col gap-0.5"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="text-xs font-medium text-n-ruby-11">
                  {{ t('CAMPAIGN.RESULTS.CONTACT_ID') }}: {{ err.contact_id }}
                </span>
                <span class="text-xs text-n-ruby-10">{{ formatTs(err.timestamp) }}</span>
              </div>
              <span class="text-xs text-n-ruby-10 break-words">{{ err.message }}</span>
            </div>
          </div>
        </div>

        <!-- No errors state -->
        <div
          v-else-if="sent > 0"
          class="text-center py-2 text-sm text-n-teal-10"
        >
          {{ t('CAMPAIGN.RESULTS.NO_ERRORS') }}
        </div>
      </div>
    </div>
  </div>
</template>
