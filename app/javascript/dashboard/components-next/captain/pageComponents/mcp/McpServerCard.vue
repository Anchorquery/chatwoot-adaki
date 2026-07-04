<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { dynamicTime } from 'shared/helpers/timeHelper';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Policy from 'dashboard/components/policy.vue';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  name: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    default: '',
  },
  endpointUrl: {
    type: String,
    default: '',
  },
  transportType: {
    type: String,
    default: 'streamable_http',
  },
  enabled: {
    type: Boolean,
    default: true,
  },
  toolsCount: {
    type: Number,
    default: 0,
  },
  credentialHint: {
    type: String,
    default: '',
  },
  lastDiscoveredAt: {
    type: [String, Number, Date],
    default: '',
  },
  updatedAt: {
    type: [String, Number, Date],
    default: '',
  },
});

const emit = defineEmits(['action']);
const { t } = useI18n();
const [showActionsDropdown, toggleDropdown] = useToggle();

const menuItems = computed(() => [
  {
    label: t('CAPTAIN.MCP.ACTIONS.EDIT'),
    value: 'edit',
    action: 'edit',
    icon: 'i-lucide-pencil-line',
  },
  {
    label: t('CAPTAIN.MCP.ACTIONS.DISCOVER', { count: props.toolsCount }),
    value: 'discover',
    action: 'discover',
    icon: 'i-lucide-scan-search',
  },
  {
    label: t('CAPTAIN.MCP.ACTIONS.TEST'),
    value: 'test',
    action: 'test',
    icon: 'i-lucide-flask-conical',
  },
  {
    label: t('CAPTAIN.MCP.ACTIONS.DELETE'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const timestamp = computed(() => {
  const value = props.lastDiscoveredAt || props.updatedAt;
  return value ? dynamicTime(value) : '';
});

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};
</script>

<template>
  <CardLayout class="relative">
    <div class="flex items-start justify-between w-full gap-3">
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <span class="text-base font-medium text-n-slate-12 truncate">{{
            name
          }}</span>
          <span
            class="inline-flex items-center px-2 py-0.5 text-xs rounded-md"
            :class="
              enabled
                ? 'bg-n-teal-2 text-n-teal-11'
                : 'bg-n-weak text-n-slate-11'
            "
          >
            {{
              enabled
                ? t('CAPTAIN.MCP.STATUS.ENABLED')
                : t('CAPTAIN.MCP.STATUS.DISABLED')
            }}
          </span>
        </div>
        <p class="mt-1 text-sm text-n-slate-11 line-clamp-2">
          {{ description || endpointUrl }}
        </p>
      </div>
      <Policy :permissions="['administrator']">
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
      </Policy>
    </div>

    <div class="mt-3 grid gap-2 text-sm text-n-slate-11 sm:grid-cols-3">
      <div>
        <span class="block text-xs uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.MCP.CARD.TOOL_COUNT') }}
        </span>
        <span>{{ toolsCount }}</span>
      </div>
      <div>
        <span class="block text-xs uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.MCP.CARD.TRANSPORT') }}
        </span>
        <span class="capitalize">{{ transportType.replace('_', ' ') }}</span>
      </div>
      <div>
        <span class="block text-xs uppercase tracking-wide text-n-slate-10">
          {{ t('CAPTAIN.MCP.CARD.CREDENTIAL') }}
        </span>
        <span>{{ credentialHint || t('CAPTAIN.MCP.CARD.NO_CREDENTIAL') }}</span>
      </div>
    </div>

    <div v-if="timestamp" class="mt-3 text-xs text-n-slate-10">
      {{ timestamp }}
    </div>
  </CardLayout>
</template>
