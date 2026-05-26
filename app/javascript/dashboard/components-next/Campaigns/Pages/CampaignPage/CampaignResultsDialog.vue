<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  campaign: { type: Object, default: null },
});

const emit = defineEmits(['close']);
const { t } = useI18n();

const ds = computed(() => props.campaign?.delivery_state || {});
const total = computed(
  () => ds.value.contact_ids?.length ?? ds.value.sent_count + ds.value.failed_count
);
const sent = computed(() => ds.value.sent_count ?? 0);
const failed = computed(() => ds.value.failed_count ?? 0);
const errors = computed(() => ds.value.errors ?? []);
const sentPct = computed(() =>
  total.value > 0 ? Math.round((sent.value / total.value) * 100) : 0
);

const formatTs = ts => {
  if (!ts) return '';
  return new Date(ts).toLocaleString();
};
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
    @click.self="emit('close')"
  >
    <div class="bg-n-solid-1 rounded-2xl shadow-xl w-full max-w-lg mx-4 flex flex-col max-h-[80vh]">
      <div class="flex items-center justify-between p-4 border-b border-n-weak">
        <div>
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ t('CAMPAIGN.RESULTS.TITLE') }}
          </h3>
          <p class="text-xs text-n-slate-10 mt-0.5 line-clamp-1">
            {{ campaign?.title }}
          </p>
        </div>
        <Button
          variant="faded"
          size="sm"
          color="slate"
          icon="i-lucide-x"
          @click="emit('close')"
        />
      </div>

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

        <div v-if="errors.length" class="flex flex-col gap-2">
          <p class="text-xs font-medium text-n-slate-11">
            {{ t('CAMPAIGN.RESULTS.ERRORS_TITLE') }} ({{ errors.length }})
          </p>
          <div class="flex flex-col gap-1 max-h-56 overflow-y-auto">
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

        <div v-else-if="sent > 0" class="text-center py-2 text-sm text-n-teal-10">
          {{ t('CAMPAIGN.RESULTS.NO_ERRORS') }}
        </div>
      </div>
    </div>
  </div>
</template>
