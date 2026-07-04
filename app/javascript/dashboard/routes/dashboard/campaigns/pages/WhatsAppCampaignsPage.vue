<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle } from '@vueuse/core';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { INBOX_TYPES } from 'dashboard/helper/inbox';
import { useCampaignList } from 'dashboard/composables/useCampaignList';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import CampaignLayout from 'dashboard/components-next/Campaigns/CampaignLayout.vue';
import CampaignFilterBar from 'dashboard/components-next/Campaigns/CampaignFilterBar.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import WhatsAppCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/WhatsAppCampaign/WhatsAppCampaignDialog.vue';
import APICampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignDialog.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import CampaignResultsDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignResultsDialog.vue';
import WhatsAppCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/WhatsAppCampaignEmptyState.vue';
import PaginationFooter from 'dashboard/components-next/pagination/PaginationFooter.vue';

const { t } = useI18n();
const store = useStore();

const {
  campaigns,
  meta,
  isFetching,
  filters,
  currentPage,
  onFilterChange,
  onPageChange,
  refresh,
} = useCampaignList([INBOX_TYPES.WHATSAPP]);

const selectedCampaign = ref(null);
const [showWhatsAppCampaignDialog, toggleWhatsAppCampaignDialog] = useToggle();
const [showEditCampaignDialog, toggleEditCampaignDialog] = useToggle();
const [showResultsDialog, toggleResultsDialog] = useToggle();
const resultsCampaign = ref(null);
const confirmDeleteCampaignDialogRef = ref(null);

const hasNoCampaigns = computed(
  () => campaigns.value?.length === 0 && !isFetching.value
);

const handleDelete = campaign => {
  selectedCampaign.value = campaign;
  confirmDeleteCampaignDialogRef.value.dialogRef.open();
};

const handleEdit = campaign => {
  selectedCampaign.value = campaign;
  toggleEditCampaignDialog(true);
};

const handleClone = async campaign => {
  try {
    const cloned = await store.dispatch('campaigns/clone', campaign.id);
    selectedCampaign.value = cloned;
    toggleEditCampaignDialog(true);
  } catch {
    useAlert(t('CAMPAIGN.CLONE.ERROR'));
  }
};

const handleResults = campaign => {
  resultsCampaign.value = campaign;
  toggleResultsDialog(true);
};

const handleDialogClose = () => {
  toggleWhatsAppCampaignDialog(false);
  refresh();
};

const handleEditDialogClose = () => {
  toggleEditCampaignDialog(false);
  refresh();
};
</script>

<template>
  <CampaignLayout
    :header-title="t('CAMPAIGN.WHATSAPP.HEADER_TITLE')"
    :button-label="t('CAMPAIGN.WHATSAPP.NEW_CAMPAIGN')"
    @click="toggleWhatsAppCampaignDialog()"
    @close="toggleWhatsAppCampaignDialog(false)"
  >
    <template #action>
      <WhatsAppCampaignDialog
        v-if="showWhatsAppCampaignDialog"
        @close="handleDialogClose"
      />
    </template>

    <template #filters>
      <CampaignFilterBar
        :model-value="filters"
        @update:model-value="onFilterChange"
      />
    </template>

    <div
      v-if="isFetching"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>
    <CampaignList
      v-else-if="!hasNoCampaigns"
      :campaigns="campaigns"
      @edit="handleEdit"
      @delete="handleDelete"
      @clone="handleClone"
      @results="handleResults"
    />
    <APICampaignDialog
      v-if="showEditCampaignDialog"
      mode="edit"
      :selected-campaign="selectedCampaign"
      @close="handleEditDialogClose"
    />
    <WhatsAppCampaignEmptyState
      v-else
      :title="t('CAMPAIGN.WHATSAPP.EMPTY_STATE.TITLE')"
      :subtitle="t('CAMPAIGN.WHATSAPP.EMPTY_STATE.SUBTITLE')"
      class="pt-14"
    />

    <ConfirmDeleteCampaignDialog
      ref="confirmDeleteCampaignDialogRef"
      :selected-campaign="selectedCampaign"
      @deleted="refresh"
    />
    <CampaignResultsDialog
      v-if="showResultsDialog"
      :campaign="resultsCampaign"
      @close="toggleResultsDialog(false)"
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
