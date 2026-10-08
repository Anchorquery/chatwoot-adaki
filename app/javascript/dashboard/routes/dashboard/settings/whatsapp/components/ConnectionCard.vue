<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ConnectionStatusBadge from './ConnectionStatusBadge.vue';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
  // { status, phone_number, profile_name, profile_picture_url, refreshing }
  connection: {
    type: Object,
    default: () => ({ status: 'loading' }),
  },
  restarting: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'qr',
  'settings',
  'privacy',
  'restart',
  'logout',
  'open',
]);

const { t } = useI18n();

const status = computed(() => props.connection.status || 'loading');
const isConnected = computed(() => status.value === 'open');
const isReachable = computed(() =>
  ['open', 'connecting', 'close'].includes(status.value)
);

const phone = computed(() =>
  props.connection.phone_number ? `+${props.connection.phone_number}` : ''
);

const subtitle = computed(() => {
  if (isConnected.value) {
    return [phone.value, props.connection.profile_name]
      .filter(Boolean)
      .join(' · ');
  }
  if (status.value === 'error') {
    return t('WHATSAPP_CONNECTIONS.CARD.UNREACHABLE_HINT');
  }
  if (status.value === 'loading') return '';
  return t('WHATSAPP_CONNECTIONS.CARD.NOT_LINKED');
});
</script>

<template>
  <article
    class="flex flex-col gap-4 p-5 rounded-2xl border bg-n-solid-1 transition-colors"
    :class="
      isConnected ? 'border-n-weak' : 'border-n-weak hover:border-n-slate-7'
    "
  >
    <header class="flex items-start gap-3">
      <Avatar
        :src="connection.profile_picture_url || inbox.avatar_url || ''"
        :name="inbox.name"
        :size="44"
        rounded-full
      />
      <div class="flex flex-col min-w-0 flex-1 gap-0.5">
        <h3 class="text-sm font-medium text-n-slate-12 truncate">
          {{ inbox.name }}
        </h3>
        <p class="text-xs text-n-slate-11 truncate min-h-4">
          {{ subtitle }}
        </p>
      </div>
      <ConnectionStatusBadge
        :status="status"
        :refreshing="connection.refreshing"
      />
    </header>

    <div class="flex items-center gap-2 pt-3 border-t border-n-weak">
      <NextButton
        v-if="!isConnected"
        type="button"
        size="sm"
        icon="i-lucide-qr-code"
        :label="$t('WHATSAPP_CONNECTIONS.ACTIONS.CONNECT')"
        :disabled="status === 'loading'"
        @click="emit('qr', inbox)"
      />
      <NextButton
        type="button"
        size="sm"
        variant="faded"
        color="slate"
        icon="i-lucide-sliders-horizontal"
        :label="$t('WHATSAPP_CONNECTIONS.ACTIONS.SETTINGS')"
        :disabled="!isReachable"
        @click="emit('settings', inbox)"
      />
      <NextButton
        v-tooltip.top="$t('WHATSAPP_CONNECTIONS.ACTIONS.PRIVACY')"
        type="button"
        size="sm"
        variant="ghost"
        color="slate"
        icon="i-lucide-shield-check"
        :aria-label="$t('WHATSAPP_CONNECTIONS.ACTIONS.PRIVACY')"
        @click="emit('privacy', inbox)"
      />
      <div class="flex-1" />
      <NextButton
        v-tooltip.top="$t('WHATSAPP_CONNECTIONS.ACTIONS.RESTART')"
        type="button"
        size="sm"
        variant="ghost"
        color="slate"
        icon="i-lucide-rotate-cw"
        :aria-label="$t('WHATSAPP_CONNECTIONS.ACTIONS.RESTART')"
        :is-loading="restarting"
        :disabled="status !== 'open' && status !== 'connecting'"
        @click="emit('restart', inbox)"
      />
      <NextButton
        v-tooltip.top="$t('WHATSAPP_CONNECTIONS.ACTIONS.OPEN_INBOX')"
        type="button"
        size="sm"
        variant="ghost"
        color="slate"
        icon="i-lucide-settings"
        :aria-label="$t('WHATSAPP_CONNECTIONS.ACTIONS.OPEN_INBOX')"
        @click="emit('open', inbox)"
      />
      <NextButton
        v-if="isConnected"
        v-tooltip.top="$t('WHATSAPP_CONNECTIONS.ACTIONS.LOGOUT')"
        type="button"
        size="sm"
        variant="ghost"
        color="ruby"
        icon="i-lucide-unplug"
        :aria-label="$t('WHATSAPP_CONNECTIONS.ACTIONS.LOGOUT')"
        @click="emit('logout', inbox)"
      />
    </div>
  </article>
</template>
