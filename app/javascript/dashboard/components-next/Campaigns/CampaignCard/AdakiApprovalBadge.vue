<script setup>
import { computed } from 'vue';

const props = defineProps({
  requiresApproval: {
    type: Boolean,
    default: false,
  },
  approvalStatus: {
    type: String,
    default: 'not_required',
  },
});

const visible = computed(
  () => props.requiresApproval && props.approvalStatus !== 'not_required'
);

const colorClass = computed(() => ({
  'bg-n-amber-2 text-n-amber-11': props.approvalStatus === 'pending',
  'bg-n-teal-2 text-n-teal-11': props.approvalStatus === 'approved',
  'bg-n-ruby-2 text-n-ruby-11': props.approvalStatus === 'rejected',
}));

const icon = computed(
  () =>
    ({
      pending: 'i-lucide-clock',
      approved: 'i-lucide-check-circle',
      rejected: 'i-lucide-x-circle',
    })[props.approvalStatus] || 'i-lucide-shield'
);

const labelKey = computed(
  () =>
    ({
      pending: 'ADAKI.APPROVALS.STATUS.PENDING',
      approved: 'ADAKI.APPROVALS.STATUS.APPROVED',
      rejected: 'ADAKI.APPROVALS.STATUS.REJECTED',
    })[props.approvalStatus] || 'ADAKI.APPROVALS.STATUS.UNKNOWN'
);
</script>

<template>
  <span
    v-if="visible"
    class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-xs font-medium"
    :class="colorClass"
    :title="$t(labelKey)"
  >
    <span :class="icon" class="size-3" aria-hidden="true" />
    {{ $t(labelKey) }}
  </span>
</template>
