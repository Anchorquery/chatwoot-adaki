<script setup>
import CampaignCard from 'dashboard/components-next/Campaigns/CampaignCard/CampaignCard.vue';

defineProps({
  campaigns: {
    type: Array,
    required: true,
  },
  isLiveChatType: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['edit', 'delete', 'clone', 'results']);

const handleEdit = campaign => emit('edit', campaign);
const handleDelete = campaign => emit('delete', campaign);
const handleClone = campaign => emit('clone', campaign);
const handleResults = campaign => emit('results', campaign);
</script>

<template>
  <div class="flex flex-col gap-4">
    <CampaignCard
      v-for="campaign in campaigns"
      :key="campaign.id"
      :title="campaign.title"
      :message="campaign.message"
      :is-enabled="campaign.enabled"
      :status="campaign.campaign_status"
      :sender="campaign.sender"
      :inbox="campaign.inbox"
      :scheduled-at="campaign.scheduled_at"
      :is-live-chat-type="isLiveChatType"
      :requires-approval="campaign.requires_approval"
      :approval-status="campaign.approval_status"
      :delivery-state="campaign.delivery_state"
      @edit="handleEdit(campaign)"
      @delete="handleDelete(campaign)"
      @clone="handleClone(campaign)"
      @results="handleResults(campaign)"
    />
  </div>
</template>
