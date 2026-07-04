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
import APICampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignDialog.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import CampaignResultsDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignResultsDialog.vue';
import SMSCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/SMSCampaignEmptyState.vue';
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
} = useCampaignList([INBOX_TYPES.API]);

const selectedCampaign = ref(null);
const dialogMode = ref('create');
const [showAPICampaignDialog, toggleAPICampaignDialog] = useToggle();
const [showResultsDialog, toggleResultsDialog] = useToggle();
const resultsCampaign = ref(null);
const confirmDeleteCampaignDialogRef = ref(null);

const hasNoCampaigns = computed(
  () => campaigns.value?.length === 0 && !isFetching.value
);

const handleCreate = () => {
  dialogMode.value = 'create';
  selectedCampaign.value = null;
  toggleAPICampaignDialog(true);
};

const handleEdit = campaign => {
  dialogMode.value = 'edit';
  selectedCampaign.value = campaign;
  toggleAPICampaignDialog(true);
};

const handleDelete = campaign => {
  selectedCampaign.value = campaign;
  confirmDeleteCampaignDialogRef.value.dialogRef.open();
};

const handleClone = async campaign => {
  try {
    const cloned = await store.dispatch('campaigns/clone', campaign.id);
    dialogMode.value = 'edit';
    selectedCampaign.value = cloned;
    toggleAPICampaignDialog(true);
  } catch {
    useAlert(t('CAMPAIGN.CLONE.ERROR'));
  }
};

const handleResults = campaign => {
  resultsCampaign.value = campaign;
  toggleResultsDialog(true);
};

const handleDialogClose = () => {
  toggleAPICampaignDialog(false);
  refresh();
};
</script>

<template>
  <CampaignLayout
    :header-title="t('CAMPAIGN.API.HEADER_TITLE')"
    :button-label="t('CAMPAIGN.API.NEW_CAMPAIGN')"
    @click="handleCreate"
    @close="toggleAPICampaignDialog(false)"
  >
    <template #action>
      <APICampaignDialog
        v-if="showAPICampaignDialog"
        :mode="dialogMode"
        :selected-campaign="selectedCampaign"
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
    <SMSCampaignEmptyState
      v-else
      :title="t('CAMPAIGN.API.EMPTY_STATE.TITLE')"
      :subtitle="t('CAMPAIGN.API.EMPTY_STATE.SUBTITLE')"
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
