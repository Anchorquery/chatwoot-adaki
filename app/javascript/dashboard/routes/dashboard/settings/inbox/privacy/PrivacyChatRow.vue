<script setup>
import { computed } from 'vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const props = defineProps({
  // { jid, name, phone, type, picture_url }
  item: {
    type: Object,
    required: true,
  },
});

const TYPE_ICONS = {
  group: 'i-lucide-users',
  channel: 'i-lucide-megaphone',
};

// Debajo del nombre, lo que identifica el chat sin ambigüedad: el teléfono si
// lo hay; si no, el JID (grupos, canales, "@lid").
const subtitle = computed(() => {
  const { phone, jid, name } = props.item;
  const value = phone ? `+${phone}` : jid;
  return value === name ? '' : value;
});
</script>

<template>
  <div class="flex items-center gap-3 min-w-0 py-2">
    <Avatar
      :src="item.picture_url || ''"
      :name="item.name || item.jid"
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
        <span class="truncate">{{ item.name || item.jid }}</span>
      </span>
      <span v-if="subtitle" class="text-xs text-n-slate-11 truncate">
        {{ subtitle }}
      </span>
    </div>
    <slot name="action" />
  </div>
</template>
