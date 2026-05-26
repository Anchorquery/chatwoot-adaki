<script setup>
import { computed, nextTick, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGN_TYPES } from 'shared/constants/campaign.js';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events.js';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import APICampaignForm from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignForm.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
  selectedCampaign: {
    type: Object,
    default: null,
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const store = useStore();

const dialogRef = ref(null);
const apiCampaignFormRef = ref(null);

const uiFlags = useMapGetter('campaigns/getUIFlags');
const isUpdatingCampaign = computed(() => uiFlags.value.isUpdating);
const isCreatingCampaign = computed(() => uiFlags.value.isCreating);
const isBusy = computed(() => isUpdatingCampaign.value || isCreatingCampaign.value);

const isInvalidForm = computed(
  () => apiCampaignFormRef.value?.isSubmitDisabled ?? true
);

const dialogTitle = computed(() =>
  props.mode === 'edit'
    ? t('CAMPAIGN.API.EDIT.TITLE')
    : t('CAMPAIGN.API.CREATE.TITLE')
);

const confirmButtonLabel = computed(() =>
  props.mode === 'edit'
    ? t('CAMPAIGN.API.CREATE.FORM.BUTTONS.UPDATE')
    : t('CAMPAIGN.API.CREATE.FORM.BUTTONS.CREATE')
);

const submitCampaign = async campaignDetails => {
  try {
    if (props.mode === 'edit' && props.selectedCampaign?.id) {
      await store.dispatch('campaigns/update', {
        id: props.selectedCampaign.id,
        payload: campaignDetails,
      });
    } else {
      await store.dispatch('campaigns/create', campaignDetails);
    }

    useTrack(
      props.mode === 'edit'
        ? CAMPAIGNS_EVENTS.UPDATE_CAMPAIGN
        : CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      {
        type: CAMPAIGN_TYPES.ONE_OFF,
      }
    );

    useAlert(
      props.mode === 'edit'
        ? t('CAMPAIGN.API.EDIT.FORM.API.SUCCESS_MESSAGE')
        : t('CAMPAIGN.API.CREATE.FORM.API.SUCCESS_MESSAGE')
    );

    dialogRef.value.close();
    emit('close');
  } catch (error) {
    const errorMessage =
      error?.response?.data?.error ||
      error?.response?.data?.message ||
      (props.mode === 'edit'
        ? t('CAMPAIGN.API.EDIT.FORM.API.ERROR_MESSAGE')
        : t('CAMPAIGN.API.CREATE.FORM.API.ERROR_MESSAGE'));
    useAlert(errorMessage);
  }
};

const handleSubmit = () => {
  if (!apiCampaignFormRef.value) return;

  submitCampaign(apiCampaignFormRef.value.prepareCampaignDetails());
};

onMounted(async () => {
  await nextTick();
  dialogRef.value?.open();
});

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="edit"
    :title="dialogTitle"
    :confirm-button-label="confirmButtonLabel"
    :cancel-button-label="t('CAMPAIGN.API.CREATE.CANCEL_BUTTON_TEXT')"
    :is-loading="isBusy"
    :disable-confirm-button="isBusy || isInvalidForm"
    overflow-y-auto
    @confirm="handleSubmit"
  >
    <div data-campaign-dialog-content @click.stop>
      <APICampaignForm
        ref="apiCampaignFormRef"
        :mode="mode"
        :selected-campaign="selectedCampaign"
        :show-action-buttons="false"
        @submit="handleSubmit"
        @cancel="emit('close')"
      />
    </div>
  </Dialog>
</template>
