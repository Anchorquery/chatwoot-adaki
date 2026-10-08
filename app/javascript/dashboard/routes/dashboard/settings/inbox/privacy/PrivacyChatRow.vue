<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const props = defineProps({
  // { jid, name, phone, type, picture_url }
  item: {
    type: Object,
    required: true,
  },
});

const { t } = useI18n();

const TYPE_ICONS = {
  group: 'i-lucide-users',
  channel: 'i-lucide-megaphone',
};

// Un "@lid" es el identificador privado que WhatsApp usa en lugar del
// teléfono: sus dígitos no significan nada para quien lo lee.
const isLid = computed(() => props.item.jid.endsWith('@lid'));

const displayName = computed(() => {
  const { name, jid } = props.item;
  const hasRealName = name && name !== jid && !name.endsWith('@lid');
  if (hasRealName) return name;
  return isLid.value ? t('PRIVACY_FILTER.UNNAMED') : name || jid;
});

// Debajo del nombre, lo que identifica el chat: el teléfono si lo hay; en un
// "@lid" sin teléfono, una etiqueta legible; en grupos y canales, su ID.
const subtitle = computed(() => {
  const { phone, jid } = props.item;
  let value = jid;
  if (phone) value = `+${phone}`;
  else if (isLid.value) value = t('PRIVACY_FILTER.PRIVATE_ID');
  return value === displayName.value ? '' : value;
});
</script>

<template>
  <div class="flex items-center gap-3 min-w-0 py-2">
    <Avatar
      :src="item.picture_url || ''"
      :name="displayName"
      :size="32"
      rounded-full
    />
    <div class="flex flex-col min-w-0 flex-1">
      <span class="flex items-center gap-1.5 text-sm text-n-slate-12 min-w-0">
        <span
          v-if="TYPE_ICONS[item.type]"
          :class="TYPE_ICONS[item.type]"
          class="size-3.5 shrink-0 text-n-slate-10"
        />
        <span class="truncate">{{ displayName }}</span>
      </span>
      <span
        v-if="subtitle"
        v-tooltip.top="isLid && !item.phone ? item.jid : null"
        class="text-xs text-n-slate-11 truncate"
      >
        {{ subtitle }}
      </span>
    </div>
    <slot name="action" />
  </div>
</template>
