<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  id: { type: Number, required: true },
  name: { type: String, required: true },
  provider: { type: String, required: true },
  providerLabel: { type: String, default: '' },
  status: { type: String, default: 'active' },
});

const emit = defineEmits(['action', 'toggle']);
const { t } = useI18n();
const [showActionsDropdown, toggleDropdown] = useToggle();

const enabled = computed(() => props.status === 'active');

const menuItems = computed(() => [
  {
    label: t('ADAKI.CAPTAIN.CREDENTIALS.ACTIONS.SYNC_MODELS'),
    value: 'sync_models',
    action: 'sync_models',
    icon: 'i-lucide-refresh-cw',
  },
  {
    label: t('ADAKI.CAPTAIN.CREDENTIALS.ACTIONS.CONFIGURE_MODELS'),
    value: 'configure_models',
    action: 'configure_models',
    icon: 'i-lucide-settings-2',
  },
  {
    label: t('ADAKI.CAPTAIN.CREDENTIALS.ACTIONS.EDIT'),
    value: 'edit',
    action: 'edit',
    icon: 'i-lucide-pencil-line',
  },
  {
    label: t('ADAKI.CAPTAIN.CREDENTIALS.ACTIONS.VALIDATE'),
    value: 'validate',
    action: 'validate',
    icon: 'i-lucide-plug-zap',
  },
  {
    label: t('ADAKI.CAPTAIN.CREDENTIALS.ACTIONS.DELETE'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};

const handleToggle = () => {
  emit('toggle', { id: props.id, enabled: !enabled.value });
};
</script>

<template>
  <CardLayout class="relative">
    <div class="flex items-start justify-between w-full gap-3">
      <div class="min-w-0">
        <div class="text-base font-medium text-n-slate-12 truncate">
          {{ name }}
        </div>
        <div class="mt-0.5 text-sm text-n-slate-11 truncate">
          {{ providerLabel || provider }}
        </div>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <button
          type="button"
          class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors"
          :class="enabled ? 'bg-n-teal-9' : 'bg-n-slate-6'"
          :title="
            enabled
              ? t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.ACTIVE')
              : t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.REVOKED')
          "
          @click="handleToggle"
        >
          <span
            class="inline-block h-5 w-5 transform rounded-full bg-white transition-transform"
            :class="enabled ? 'translate-x-5' : 'translate-x-1'"
          />
        </button>
        <div class="relative">
          <Button
            icon="i-lucide-ellipsis-vertical"
            color="slate"
            size="xs"
            class="rounded-md"
            @click="toggleDropdown()"
          />
          <DropdownMenu
            v-if="showActionsDropdown"
            :menu-items="menuItems"
            class="mt-1 ltr:right-0 rtl:right-0 top-full"
            @action="handleAction($event)"
          />
        </div>
      </div>
    </div>

    <div class="mt-3 flex flex-wrap items-center gap-2">
      <span
        class="inline-flex items-center px-2 py-0.5 text-xs rounded-md"
        :class="
          enabled
            ? 'bg-n-teal-2 text-n-teal-11'
            : 'bg-n-slate-3 text-n-slate-11'
        "
      >
        {{ t('ADAKI.CAPTAIN.CREDENTIALS.BADGE.PLATFORM') }}
      </span>
      <span
        class="inline-flex items-center px-2 py-0.5 text-xs rounded-md bg-n-slate-3 text-n-slate-11"
      >
        {{ t('ADAKI.CAPTAIN.CREDENTIALS.BADGE.API_KEY') }}
      </span>
      <span
        v-if="status && status !== 'active'"
        class="inline-flex items-center px-2 py-0.5 text-xs rounded-md bg-n-amber-2 text-n-amber-11"
      >
        {{ status }}
      </span>
    </div>
  </CardLayout>
</template>
