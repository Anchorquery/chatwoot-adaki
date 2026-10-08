<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import NextButton from 'dashboard/components-next/button/Button.vue';
import PrivacyChatRow from './PrivacyChatRow.vue';

const props = defineProps({
  items: {
    type: Array,
    default: () => [],
  },
  mode: {
    type: String,
    default: 'block',
  },
});

const emit = defineEmits(['remove', 'clear']);

const { t } = useI18n();

const filter = ref('');

const GROUP_ORDER = ['contact', 'group', 'channel'];

const visibleItems = computed(() => {
  const query = filter.value.trim().toLowerCase();
  if (!query) return props.items;
  return props.items.filter(
    item =>
      (item.name || '').toLowerCase().includes(query) ||
      item.jid.includes(query)
  );
});

const groups = computed(() =>
  GROUP_ORDER.map(type => ({
    type,
    label: t(`PRIVACY_FILTER.TYPES.${type.toUpperCase()}`),
    items: visibleItems.value.filter(item => item.type === type),
  })).filter(group => group.items.length)
);

const title = computed(() =>
  props.mode === 'allow'
    ? t('PRIVACY_FILTER.SELECTED.TITLE_ALLOW', { count: props.items.length })
    : t('PRIVACY_FILTER.SELECTED.TITLE_BLOCK', { count: props.items.length })
);
</script>

<template>
  <section
    class="flex flex-col gap-3 p-4 rounded-2xl border border-n-weak min-h-[24rem]"
  >
    <header class="flex items-center justify-between gap-2">
      <h3 class="text-sm font-medium text-n-slate-12">{{ title }}</h3>
      <NextButton
        v-if="items.length"
        type="button"
        size="xs"
        variant="ghost"
        color="slate"
        :label="$t('PRIVACY_FILTER.SELECTED.CLEAR')"
        @click="emit('clear')"
      />
    </header>

    <input
      v-if="items.length > 8"
      v-model="filter"
      type="search"
      class="!mb-0 text-sm"
      :placeholder="$t('PRIVACY_FILTER.SELECTED.FILTER_PLACEHOLDER')"
    />

    <div
      v-if="!items.length"
      class="flex flex-col items-center justify-center flex-1 gap-2 py-10 text-center"
    >
      <span class="i-lucide-mouse-pointer-click size-6 text-n-slate-9" />
      <p class="text-sm text-n-slate-11 max-w-xs">
        {{
          mode === 'allow'
            ? $t('PRIVACY_FILTER.SELECTED.EMPTY_ALLOW')
            : $t('PRIVACY_FILTER.SELECTED.EMPTY_BLOCK')
        }}
      </p>
    </div>

    <div v-else class="flex flex-col gap-4 overflow-y-auto max-h-[32rem]">
      <div v-for="group in groups" :key="group.type" class="flex flex-col">
        <p class="text-xs font-medium text-n-slate-10 uppercase tracking-wide">
          {{ group.label }} · {{ group.items.length }}
        </p>
        <PrivacyChatRow
          v-for="item in group.items"
          :key="item.jid"
          :item="item"
          class="border-b border-n-weak last:border-b-0"
        >
          <template #action>
            <NextButton
              v-tooltip.top="$t('PRIVACY_FILTER.SELECTED.REMOVE')"
              type="button"
              size="xs"
              variant="ghost"
              color="slate"
              icon="i-lucide-x"
              :aria-label="$t('PRIVACY_FILTER.SELECTED.REMOVE')"
              @click="emit('remove', item)"
            />
          </template>
        </PrivacyChatRow>
      </div>
      <p v-if="!groups.length" class="py-6 text-sm text-center text-n-slate-11">
        {{ $t('PRIVACY_FILTER.SEARCH.NO_RESULTS') }}
      </p>
    </div>
  </section>
</template>
