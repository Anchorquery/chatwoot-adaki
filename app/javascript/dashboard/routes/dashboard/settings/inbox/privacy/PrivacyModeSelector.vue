<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

const mode = defineModel({ type: String, default: 'all' });

const { t } = useI18n();

const OPTIONS = [
  { value: 'all', icon: 'i-lucide-inbox' },
  { value: 'block', icon: 'i-lucide-ban' },
  { value: 'allow', icon: 'i-lucide-list-checks' },
];

const options = computed(() =>
  OPTIONS.map(option => ({
    ...option,
    title: t(`PRIVACY_FILTER.MODES.${option.value.toUpperCase()}.TITLE`),
    description: t(
      `PRIVACY_FILTER.MODES.${option.value.toUpperCase()}.DESCRIPTION`
    ),
  }))
);
</script>

<template>
  <div
    role="radiogroup"
    :aria-label="$t('PRIVACY_FILTER.MODES.LABEL')"
    class="grid grid-cols-1 md:grid-cols-3 gap-3"
  >
    <button
      v-for="option in options"
      :key="option.value"
      type="button"
      role="radio"
      :aria-checked="mode === option.value"
      class="flex items-start gap-3 p-4 text-start rounded-xl border transition-colors"
      :class="
        mode === option.value
          ? 'border-n-brand bg-n-brand/5 ring-1 ring-n-brand'
          : 'border-n-weak hover:border-n-slate-7'
      "
      @click="mode = option.value"
    >
      <span
        class="flex items-center justify-center size-9 shrink-0 rounded-lg"
        :class="
          mode === option.value
            ? 'bg-n-brand text-white'
            : 'bg-n-alpha-2 text-n-slate-11'
        "
      >
        <span :class="option.icon" class="size-4" />
      </span>
      <span class="flex flex-col gap-0.5">
        <span class="text-sm font-medium text-n-slate-12">
          {{ option.title }}
        </span>
        <span class="text-xs text-n-slate-11">{{ option.description }}</span>
      </span>
    </button>
  </div>
</template>
