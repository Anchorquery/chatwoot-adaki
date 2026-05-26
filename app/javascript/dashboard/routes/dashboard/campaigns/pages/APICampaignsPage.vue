<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle } from '@vueuse/core';
import { useStoreGetters, useMapGetter } from 'dashboard/composables/store';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import CampaignLayout from 'dashboard/components-next/Campaigns/CampaignLayout.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import APICampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignDialog.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import SMSCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/SMSCampaignEmptyState.vue';

const { t } = useI18n();
const getters = useStoreGetters();

const selectedCampaign = ref(null);
const dialogMode = ref('create');
const [showAPICampaignDialog, toggleAPICampaignDialog] = useToggle();

const uiFlags = useMapGetter('campaigns/getUIFlags');
const isFetchingCampaigns = computed(() => uiFlags.value.isFetching);

const confirmDeleteCampaignDialogRef = ref(null);

const apiCampaigns = computed(() => getters['campaigns/getAPICampaigns'].value);

const hasNoAPICampaigns = computed(
  () => apiCampaigns.value?.length === 0 && !isFetchingCampaigns.value
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
        @close="toggleAPICampaignDialog(false)"
      />
    </template>

    <div
      v-if="isFetchingCampaigns"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>
    <CampaignList
      v-else-if="!hasNoAPICampaigns"
      :campaigns="apiCampaigns"
      @edit="handleEdit"
      @delete="handleDelete"
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
    />
  </CampaignLayout>
</template>
