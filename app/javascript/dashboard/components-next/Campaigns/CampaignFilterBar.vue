<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import FilterSelect from 'dashboard/components-next/filter/inputs/FilterSelect.vue';

const props = defineProps({
  modelValue: {
    type: Object,
    default: () => ({ status: '', q: '' }),
  },
});

const emit = defineEmits(['update:modelValue']);

const { t } = useI18n();

const searchInput = ref(props.modelValue.q || '');
let searchTimer = null;

const statusOptions = computed(() => [
  { label: t('CAMPAIGN.FILTER.STATUS_ALL'), value: '' },
  { label: t('CAMPAIGN.FILTER.STATUS_ACTIVE'), value: 'active' },
  { label: t('CAMPAIGN.FILTER.STATUS_RUNNING'), value: 'running' },
  { label: t('CAMPAIGN.FILTER.STATUS_PAUSED'), value: 'paused' },
  { label: t('CAMPAIGN.FILTER.STATUS_COMPLETED'), value: 'completed' },
  { label: t('CAMPAIGN.FILTER.STATUS_FAILED'), value: 'failed' },
  { label: t('CAMPAIGN.FILTER.STATUS_DRAFT'), value: 'draft' },
]);

const selectedStatus = computed({
  get: () => props.modelValue.status,
  set: val => emit('update:modelValue', { ...props.modelValue, status: val }),
});

function onSearchInput(e) {
  clearTimeout(searchTimer);
  searchInput.value = e.target.value;
  searchTimer = setTimeout(() => {
    emit('update:modelValue', { ...props.modelValue, q: searchInput.value });
  }, 300);
}
</script>

<template>
  <div class="flex items-center gap-2 py-3">
    <div class="relative flex-1 max-w-xs">
      <span
        class="absolute left-3 top-1/2 -translate-y-1/2 i-lucide-search w-3.5 h-3.5 text-n-slate-9 pointer-events-none"
      />
      <input
        :value="searchInput"
        class="w-full pl-8 pr-3 py-1.5 text-sm rounded-lg bg-n-input-background border border-n-weak text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:ring-1 focus:ring-n-brand"
        :placeholder="t('CAMPAIGN.FILTER.SEARCH_PLACEHOLDER')"
        @input="onSearchInput"
      />
    </div>

    <FilterSelect
      v-model="selectedStatus"
      :options="statusOptions"
      :label="t('CAMPAIGN.FILTER.STATUS_LABEL')"
      variant="faded"
    />
  </div>
</template>
