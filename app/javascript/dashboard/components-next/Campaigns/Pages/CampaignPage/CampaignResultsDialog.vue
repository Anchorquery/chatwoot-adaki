<script setup>
import { computed, ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import ContactAPI from 'dashboard/api/contacts';

const props = defineProps({
  campaign: { type: Object, default: null },
});

const emit = defineEmits(['close']);
const { t } = useI18n();

const activeTab = ref('sent');
const contactMap = ref({});
const loadingContacts = ref(false);

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

const allContactIds = computed(() => ds.value.contact_ids ?? []);

const contactName = id => contactMap.value[id]?.name || '';
const contactPhone = id => contactMap.value[id]?.phone_number || '';

onMounted(async () => {
  if (!allContactIds.value.length) return;
  loadingContacts.value = true;
  const results = await Promise.allSettled(
    allContactIds.value.map(id => ContactAPI.show(id))
  );
  results.forEach((result, i) => {
    if (result.status === 'fulfilled') {
      const c = result.value.data;
      contactMap.value[allContactIds.value[i]] = {
        name: c.name || '',
        phone_number: c.phone_number || c.email || '',
      };
    }
  });
  loadingContacts.value = false;
});

const formatTs = ts => {
  if (!ts) return '';
  return new Date(ts).toLocaleString();
};

const exportCSV = () => {
  const rows = [
    [
      t('CAMPAIGN.RESULTS.CONTACT_ID'),
      t('CAMPAIGN.RESULTS.CONTACT_NAME'),
      t('CAMPAIGN.RESULTS.CONTACT_PHONE'),
      'Estado',
      'Error',
      'Fecha',
    ],
  ];

  sentContactIds.value.forEach(id => {
    rows.push([
      id,
      contactName(id),
      contactPhone(id),
      'enviado',
      '',
      '',
    ]);
  });

  errors.value.forEach(err => {
    const id = err.contact_id;
    rows.push([
      id,
      contactName(id),
      contactPhone(id),
      'fallido',
      err.message ?? '',
      formatTs(err.timestamp),
    ]);
  });

  const csv =
    rows.map(r => r.map(v => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  const title = (props.campaign?.title ?? 'resultados')
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

      <div class="p-4 flex flex-col gap-4 overflow-y-auto">
        <!-- Stats -->
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

          <!-- Loading -->
          <div v-if="loadingContacts" class="flex items-center justify-center py-6 text-xs text-n-slate-10 gap-2">
            <span class="i-lucide-loader-2 animate-spin w-4 h-4" />
            {{ t('CAMPAIGN.RESULTS.LOADING_CONTACTS') }}
          </div>

          <!-- Sent contacts list -->
          <div
            v-else-if="activeTab === 'sent'"
            class="flex flex-col gap-1 max-h-60 overflow-y-auto"
          >
            <div
              v-for="contactId in sentContactIds"
              :key="contactId"
              class="rounded-lg bg-n-alpha-2 px-3 py-2 flex items-center justify-between gap-2"
            >
              <div class="flex flex-col min-w-0">
                <span class="text-xs font-medium text-n-slate-12 truncate">
                  {{ contactName(contactId) || `#${contactId}` }}
                </span>
                <span v-if="contactPhone(contactId)" class="text-xs text-n-slate-10 truncate">
                  {{ contactPhone(contactId) }}
                </span>
                <span v-else class="text-xs text-n-slate-9">
                  ID: {{ contactId }}
                </span>
              </div>
              <span class="i-lucide-check text-n-teal-9 w-4 h-4 flex-shrink-0" />
            </div>
          </div>

          <!-- Errors list -->
          <div
            v-else-if="activeTab === 'errors'"
            class="flex flex-col gap-1 max-h-60 overflow-y-auto"
          >
            <div
              v-for="(err, i) in errors"
              :key="i"
              class="rounded-lg bg-n-ruby-3 px-3 py-2 flex flex-col gap-0.5"
            >
              <div class="flex items-start justify-between gap-2">
                <div class="flex flex-col min-w-0">
                  <span class="text-xs font-medium text-n-ruby-11 truncate">
                    {{ contactName(err.contact_id) || `#${err.contact_id}` }}
                  </span>
                  <span v-if="contactPhone(err.contact_id)" class="text-xs text-n-ruby-10 truncate">
                    {{ contactPhone(err.contact_id) }}
                  </span>
                  <span v-else class="text-xs text-n-ruby-9">
                    ID: {{ err.contact_id }}
                  </span>
                </div>
                <span class="text-xs text-n-ruby-10 flex-shrink-0">{{ formatTs(err.timestamp) }}</span>
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
