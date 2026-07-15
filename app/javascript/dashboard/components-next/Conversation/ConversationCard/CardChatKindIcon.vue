<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Icon from 'dashboard/components-next/icon/Icon.vue';

const props = defineProps({
  isGroup: {
    type: Boolean,
    default: false,
  },
  isWhatsappChannel: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();

// A conversation is never expected to be both, but if the backend's heuristic
// ever flags both (e.g. an unrelated "@g.us"/"@newsletter" substring showing up
// in nested additional_attributes), pick the same precedence the backend uses
// everywhere else (Conversation#group?, checked before #whatsapp_channel?, in
// HookExecutionService#broadcast_scope and CaptainInboxAudience#matches?):
// group wins.
const iconName = computed(() => {
  if (props.isGroup) return 'i-lucide-users';
  if (props.isWhatsappChannel) return 'i-lucide-radio';
  return '';
});

const tooltipContent = computed(() => {
  if (props.isGroup) {
    return t('CHAT_LIST.CHAT_KIND.WHATSAPP_GROUP');
  }
  if (props.isWhatsappChannel) {
    return t('CHAT_LIST.CHAT_KIND.WHATSAPP_CHANNEL');
  }
  return '';
});
</script>

<template>
  <Icon
    v-if="iconName"
    v-tooltip.top="{
      content: tooltipContent,
      delay: { show: 500, hide: 0 },
    }"
    :icon="iconName"
    class="size-4 text-n-slate-11 flex-shrink-0"
  />
</template>
