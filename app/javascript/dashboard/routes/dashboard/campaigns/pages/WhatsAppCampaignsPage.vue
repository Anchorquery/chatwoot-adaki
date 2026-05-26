<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle } from '@vueuse/core';
import { useStoreGetters, useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import CampaignLayout from 'dashboard/components-next/Campaigns/CampaignLayout.vue';
import CampaignList from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignList.vue';
import WhatsAppCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/WhatsAppCampaign/WhatsAppCampaignDialog.vue';
import APICampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignDialog.vue';
import ConfirmDeleteCampaignDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/ConfirmDeleteCampaignDialog.vue';
import CampaignResultsDialog from 'dashboard/components-next/Campaigns/Pages/CampaignPage/CampaignResultsDialog.vue';
import WhatsAppCampaignEmptyState from 'dashboard/components-next/Campaigns/EmptyState/WhatsAppCampaignEmptyState.vue';

const { t } = useI18n();
const getters = useStoreGetters();
const store = useStore();

const selectedCampaign = ref(null);
const [showWhatsAppCampaignDialog, toggleWhatsAppCampaignDialog] = useToggle();
const [showEditCampaignDialog, toggleEditCampaignDialog] = useToggle();
const [showResultsDialog, toggleResultsDialog] = useToggle();
const resultsCampaign = ref(null);

const uiFlags = useMapGetter('campaigns/getUIFlags');
const isFetchingCampaigns = computed(() => uiFlags.value.isFetching);

const confirmDeleteCampaignDialogRef = ref(null);

const WhatsAppCampaigns = computed(
  () => getters['campaigns/getWhatsAppCampaigns'].value
);

const hasNoWhatsAppCampaigns = computed(
  () => WhatsAppCampaigns.value?.length === 0 && !isFetchingCampaigns.value
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
        @close="toggleWhatsAppCampaignDialog(false)"
      />
    </template>
    <div
      v-if="isFetchingCampaigns"
      class="flex items-center justify-center py-10 text-n-slate-11"
    >
      <Spinner />
    </div>
    <CampaignList
      v-else-if="!hasNoWhatsAppCampaigns"
      :campaigns="WhatsAppCampaigns"
      @edit="handleEdit"
      @delete="handleDelete"
      @clone="handleClone"
      @results="handleResults"
    />
    <APICampaignDialog
      v-if="showEditCampaignDialog"
      mode="edit"
      :selected-campaign="selectedCampaign"
      @close="toggleEditCampaignDialog(false)"
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
    />
    <CampaignResultsDialog
      v-if="showResultsDialog"
      :campaign="resultsCampaign"
      @close="toggleResultsDialog(false)"
    />
  </CampaignLayout>
</template>
