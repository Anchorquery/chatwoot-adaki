<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle } from '@vueuse/core';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useCampaignList } from 'dashboard/composables/useCampaignList';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import CampaignLayout from 'dashboard/components-next/Campaigns/CampaignLayout.vue';
import CampaignFilterBar from 'dashboard/components-next/Campaigns/CampaignFilterBar.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import LiveChatCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/LiveChatCampaign/LiveChatCampaignDialog.vue';
import EditLiveChatCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/LiveChatCampaign/EditLiveChatCampaignDialog.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import LiveChatCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/LiveChatCampaignEmptyState.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';

const { t } = useI18n();

const {
  campaigns,
  meta,
  isFetching,
  filters,
  currentPage,
  onFilterChange,
  onPageChange,
  refresh,
} = useCampaignList([INBOX_TYPES.WEB]);

const editLiveChatCampaignDialogRef = ref(null);
const confirmDeleteCampaignDialogRef = ref(null);
const selectedCampaign = ref(null);

const [showLiveChatCampaignDialog, toggleLiveChatCampaignDialog] = useToggle();

const hasNoCampaigns = computed(
  () => campaigns.value?.length === 0 && !isFetching.value
);

const handleEdit = campaign => {
  selectedCampaign.value = campaign;
  editLiveChatCampaignDialogRef.value.dialogRef.open();
};

const handleDelete = campaign => {
  selectedCampaign.value = campaign;
  confirmDeleteCampaignDialogRef.value.dialogRef.open();
};
</script>

<template>
  <CampaignLayout
    :header-title="t('CAMPAIGN.LIVE_CHAT.HEADER_TITLE')"
    :button-label="t('CAMPAIGN.LIVE_CHAT.NEW_CAMPAIGN')"
    @click="toggleLiveChatCampaignDialog()"
    @close="toggleLiveChatCampaignDialog(false)"
  >
    <template #action>
      <LiveChatCampaignDialog
        v-if="showLiveChatCampaignDialog"
        @close="toggleLiveChatCampaignDialog(false)"
      />
    </template>

    <template #filters>
      <CampaignFilterBar :model-value="filters" @update:model-value="onFilterChange" />
    </template>

    <div
      v-if="isFetching"
      class="flex justify-center items-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>
    <CampaignList
      v-else-if="!hasNoCampaigns"
      :campaigns="campaigns"
      is-live-chat-type
      @edit="handleEdit"
      @delete="handleDelete"
    />
    <LiveChatCampaignEmptyState
      v-else
      :title="t('CAMPAIGN.LIVE_CHAT.EMPTY_STATE.TITLE')"
      :subtitle="t('CAMPAIGN.LIVE_CHAT.EMPTY_STATE.SUBTITLE')"
      class="pt-14"
    />

    <EditLiveChatCampaignDialog
      ref="editLiveChatCampaignDialogRef"
      :selected-campaign="selectedCampaign"
    />
    <ConfirmDeleteCampaignDialog
      ref="confirmDeleteCampaignDialogRef"
      :selected-campaign="selectedCampaign"
      @deleted="refresh"
    />

    <template #pagination>
      <PaginationFooter
        v-if="meta.totalCount > meta.perPage"
        :current-page="currentPage"
        :total-items="meta.totalCount"
        :items-per-page="meta.perPage"
        @update:current-page="onPageChange"
      />
    </template>
  </CampaignLayout>
</template>
