<script setup>
import { computed } from 'vue';

const props = defineProps({
  // loading | open | connecting | close | error
  status: {
    type: String,
    default: 'loading',
  },
  refreshing: {
    type: Boolean,
    default: false,
  },
});

// El color nunca va solo: siempre acompaña al texto del estado.
const STYLES = {
  open: {
    dot: 'bg-n-teal-9',
    pill: 'bg-n-teal-3 text-n-teal-11',
    pulse: false,
  },
  connecting: {
    dot: 'bg-n-amber-9',
    pill: 'bg-n-amber-3 text-n-amber-11',
    pulse: true,
  },
  close: {
    dot: 'bg-n-ruby-9',
    pill: 'bg-n-ruby-3 text-n-ruby-11',
    pulse: false,
  },
  error: {
    dot: 'bg-n-slate-9',
    pill: 'bg-n-slate-3 text-n-slate-11',
    pulse: false,
  },
  loading: {
    dot: 'bg-n-slate-7',
    pill: 'bg-n-slate-3 text-n-slate-11',
    pulse: true,
  },
};

const style = computed(() => STYLES[props.status] || STYLES.error);
</script>

<template>
  <span
    class="inline-flex items-center gap-1.5 shrink-0 rounded-full px-2.5 py-1 text-xs font-medium"
    :class="[style.pill, { 'opacity-70': refreshing }]"
  >
    <span class="relative flex size-2">
      <span
        v-if="style.pulse"
        class="absolute inline-flex size-full rounded-full animate-ping opacity-60"
        :class="style.dot"
      />
      <span
        class="relative inline-flex size-2 rounded-full"
        :class="style.dot"
      />
    </span>
    {{ $t(`WHATSAPP_CONNECTIONS.STATUS.${status.toUpperCase()}`) }}
  </span>
</template>
