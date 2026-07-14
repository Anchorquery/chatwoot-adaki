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

const iconName = computed(() => {
  if (props.isWhatsappChannel) return 'i-lucide-radio';
  if (props.isGroup) return 'i-lucide-users';
  return '';
});

const tooltipContent = computed(() => {
  if (props.isWhatsappChannel) {
    return t('CHAT_LIST.CHAT_KIND.WHATSAPP_CHANNEL');
  }
  if (props.isGroup) {
    return t('CHAT_LIST.CHAT_KIND.WHATSAPP_GROUP');
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
