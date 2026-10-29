<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { CAMPAIGN_TYPES } from 'shared/constants/campaign.js';
import { CAMPAIGNS_EVENTS } from 'dashboard/helper/AnalyticsHelper/events.js';

import CampaignsAPI from 'dashboard/api/campaigns';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import APICampaignForm from 'dashboard/components-next/Campaigns/Pages/CampaignPage/APICampaign/APICampaignForm.vue';

// CampaignsPageRouteView excluye este nombre de su keep-alive: cada visita
// empieza con el formulario limpio.
defineOptions({ name: 'APICampaignEditorPage' });

const { t } = useI18n();
const route = useRoute();
const router = useRouter();
const store = useStore();

const formRef = ref(null);
const campaign = ref(null);
const isLoading = ref(false);

const campaignId = computed(() => route.params.campaignId);
const mode = computed(() => (campaignId.value ? 'edit' : 'create'));

const uiFlags = useMapGetter('campaigns/getUIFlags');
const isBusy = computed(
  () => uiFlags.value.isCreating || uiFlags.value.isUpdating
);
const isInvalidForm = computed(() => formRef.value?.isSubmitDisabled ?? true);

const pageTitle = computed(() =>
  mode.value === 'edit'
    ? t('CAMPAIGN.API.EDIT.TITLE')
    : t('CAMPAIGN.API.CREATE.TITLE')
);
const submitLabel = computed(() =>
  mode.value === 'edit'
    ? t('CAMPAIGN.API.CREATE.FORM.BUTTONS.UPDATE')
    : t('CAMPAIGN.API.CREATE.FORM.BUTTONS.CREATE')
);

const goToList = () => {
  router.push({ name: 'campaigns_api_index', params: route.params });
};

const loadCampaign = async () => {
  if (!campaignId.value) return;

  isLoading.value = true;
  try {
    const { data } = await CampaignsAPI.show(campaignId.value);
    campaign.value = data;
  } catch {
    useAlert(t('CAMPAIGN.API.CREATE.PAGE.LOAD_ERROR'));
    goToList();
  } finally {
    isLoading.value = false;
  }
};

const handleSubmit = async () => {
  if (!formRef.value) return;

  const payload = formRef.value.prepareCampaignDetails();
  const isEdit = mode.value === 'edit';
  try {
    if (isEdit) {
      await store.dispatch('campaigns/update', {
        id: campaignId.value,
        payload,
      });
    } else {
      await store.dispatch('campaigns/create', payload);
    }

    useTrack(
      isEdit
        ? CAMPAIGNS_EVENTS.UPDATE_CAMPAIGN
        : CAMPAIGNS_EVENTS.CREATE_CAMPAIGN,
      { type: CAMPAIGN_TYPES.ONE_OFF }
    );
    useAlert(
      isEdit
        ? t('CAMPAIGN.API.EDIT.FORM.API.SUCCESS_MESSAGE')
        : t('CAMPAIGN.API.CREATE.FORM.API.SUCCESS_MESSAGE')
    );
    goToList();
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        error?.response?.data?.message ||
        (isEdit
          ? t('CAMPAIGN.API.EDIT.FORM.API.ERROR_MESSAGE')
          : t('CAMPAIGN.API.CREATE.FORM.API.ERROR_MESSAGE'))
    );
  }
};

onMounted(loadCampaign);
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header
      class="sticky top-0 z-10 px-6 border-b border-n-weak bg-n-surface-1"
    >
      <div
        class="flex items-center justify-between w-full h-16 gap-3 mx-auto max-w-6xl"
      >
        <div class="flex items-center min-w-0 gap-2">
          <Button
            icon="i-lucide-arrow-left"
            variant="ghost"
            color="slate"
            size="sm"
            :aria-label="t('CAMPAIGN.API.CREATE.PAGE.BACK')"
            @click="goToList"
          />
          <span class="truncate text-heading-2 text-n-slate-12">
            {{ pageTitle }}
          </span>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <Button
            variant="faded"
            color="slate"
            size="sm"
            :label="t('CAMPAIGN.API.CREATE.CANCEL_BUTTON_TEXT')"
            @click="goToList"
          />
          <Button
            size="sm"
            :label="submitLabel"
            :is-loading="isBusy"
            :disabled="isBusy || isLoading || isInvalidForm"
            @click="handleSubmit"
          />
        </div>
      </div>
    </header>

    <main class="flex-1 min-h-0 px-6 overflow-y-auto">
      <div class="w-full py-6 mx-auto max-w-6xl">
        <div
          v-if="isLoading"
          class="flex items-center justify-center py-10 text-n-slate-11"
        >
          <Spinner />
        </div>
        <APICampaignForm
          v-else
          ref="formRef"
          layout="page"
          :mode="mode"
          :selected-campaign="campaign"
          :show-action-buttons="false"
        />
      </div>
    </main>
  </section>
</template>
