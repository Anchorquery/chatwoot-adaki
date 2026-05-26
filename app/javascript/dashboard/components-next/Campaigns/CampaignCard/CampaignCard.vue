<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import LiveChatCampaignDetails from './LiveChatCampaignDetails.vue';
import SMSCampaignDetails from './SMSCampaignDetails.vue';
import AdakiApprovalBadge from './AdakiApprovalBadge.vue';

const props = defineProps({
  title: {
    type: String,
    default: '',
  },
  message: {
    type: String,
    default: '',
  },
  isLiveChatType: {
    type: Boolean,
    default: false,
  },
  isEnabled: {
    type: Boolean,
    default: false,
  },
  status: {
    type: String,
    default: '',
  },
  sender: {
    type: Object,
    default: null,
  },
  inbox: {
    type: Object,
    default: null,
  },
  scheduledAt: {
    type: Number,
    default: 0,
  },
  requiresApproval: {
    type: Boolean,
    default: false,
  },
  approvalStatus: {
    type: String,
    default: 'not_required',
  },
  deliveryState: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['edit', 'delete', 'clone', 'results']);

const { t } = useI18n();

const STATUS_COMPLETED = 'completed';
const STATUS_RUNNING = 'running';
const STATUS_PAUSED = 'paused';
const STATUS_FAILED = 'failed';
const STATUS_DRAFT = 'draft';

const { formatMessage } = useMessageFormatter();

const isActive = computed(() =>
  props.isLiveChatType ? props.isEnabled : props.status !== STATUS_COMPLETED
);

const statusTextColor = computed(() => {
  if (props.status === STATUS_FAILED) return { 'text-n-ruby-11': true };
  if (props.status === STATUS_PAUSED) return { 'text-n-amber-11': true };
  if (props.status === STATUS_RUNNING) return { 'text-n-blue-11': true };
  return {
    'text-n-teal-11': isActive.value,
    'text-n-slate-12': !isActive.value,
  };
});

const campaignStatus = computed(() => {
  if (props.isLiveChatType) {
    return props.isEnabled
      ? t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.ENABLED')
      : t('CAMPAIGN.LIVE_CHAT.CARD.STATUS.DISABLED');
  }

  switch (props.status) {
    case STATUS_COMPLETED:
      return t('CAMPAIGN.SMS.CARD.STATUS.COMPLETED');
    case STATUS_RUNNING:
      return t('CAMPAIGN.SMS.CARD.STATUS.RUNNING');
    case STATUS_PAUSED:
      return t('CAMPAIGN.SMS.CARD.STATUS.PAUSED');
    case STATUS_FAILED:
      return t('CAMPAIGN.SMS.CARD.STATUS.FAILED');
    case STATUS_DRAFT:
      return t('CAMPAIGN.SMS.CARD.STATUS.DRAFT');
    default:
      return t('CAMPAIGN.SMS.CARD.STATUS.SCHEDULED');
  }
});

const inboxName = computed(() => props.inbox?.name || '');

const inboxIcon = computed(() => {
  const { medium, channel_type: type } = props.inbox || {};
  return getInboxIconByType(type, medium);
});

const showEditButton = computed(() => props.status !== STATUS_COMPLETED);
const hasDeliveryResults = computed(
  () =>
    props.deliveryState?.sent_count > 0 ||
    props.deliveryState?.failed_count > 0
);
</script>

<template>
  <CardLayout layout="row">
    <div class="flex flex-col items-start justify-between flex-1 min-w-0 gap-2">
      <div class="flex justify-between gap-3 w-fit">
        <span
          class="text-base font-medium capitalize text-n-slate-12 line-clamp-1"
        >
          {{ title }}
        </span>
        <span
          class="text-xs font-medium inline-flex items-center h-6 px-2 py-0.5 rounded-md bg-n-alpha-2"
          :class="statusTextColor"
        >
          {{ campaignStatus }}
        </span>
        <AdakiApprovalBadge
          :requires-approval="requiresApproval"
          :approval-status="approvalStatus"
        />
      </div>
      <div
        v-dompurify-html="formatMessage(message, false, false, false)"
        class="text-sm text-n-slate-11 line-clamp-1 [&>p]:mb-0 h-6"
      />
      <div class="flex items-center w-full h-6 gap-2 overflow-hidden">
        <LiveChatCampaignDetails
          v-if="isLiveChatType"
          :sender="sender"
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
        />
        <SMSCampaignDetails
          v-else
          :inbox-name="inboxName"
          :inbox-icon="inboxIcon"
          :scheduled-at="scheduledAt"
        />
      </div>
    </div>
    <div class="flex items-center justify-end gap-2 flex-shrink-0">
      <Button
        v-if="hasDeliveryResults"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-bar-chart-2"
        @click="emit('results')"
      />
      <Button
        v-if="!isLiveChatType"
        variant="faded"
        size="sm"
        color="slate"
        icon="i-lucide-copy"
        @click="emit('clone')"
      />
      <Button
        v-if="showEditButton"
        variant="faded"
        size="sm"
        color="slate"
        :icon="isLiveChatType ? 'i-lucide-sliders-vertical' : 'i-lucide-pencil'"
        @click="emit('edit')"
      />
      <Button
        variant="faded"
        color="ruby"
        size="sm"
        icon="i-lucide-trash"
        @click="emit('delete')"
      />
    </div>
  </CardLayout>
</template>
