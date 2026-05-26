<script setup>
import { reactive, computed, ref, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { minLength, requiredIf, url } from '@vuelidate/validators';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['submit', 'cancel']);

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB

const { t } = useI18n();

const formState = {
  uiFlags: useMapGetter('captainDocuments/getUIFlags'),
};

const initialState = {
  name: '',
  url: '',
  documentType: 'web',
  crawlDepth: 10,
  pdfFile: null,
};

const state = reactive({ ...initialState });
const fileInputRef = ref(null);

const validationRules = {
  url: {
    required: requiredIf(() => state.documentType === 'web'),
    url: value =>
      state.documentType !== 'web' || url(value || '') === true,
    minLength: value =>
      state.documentType !== 'web' || minLength(1)(value || '') === true,
  },
  pdfFile: {
    required: requiredIf(() => state.documentType === 'pdf'),
  },
};

const documentTypeOptions = [
  { value: 'web', label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.WEB') },
  { value: 'pdf', label: t('CAPTAIN.DOCUMENTS.FORM.TYPE.PDF') },
];

const v$ = useVuelidate(validationRules, state);

const isLoading = computed(() => formState.uiFlags.value.creatingItem);

const hasPdfFileError = computed(() => v$.value.pdfFile.$error);
const webUrlHelpText = computed(() =>
  t('CAPTAIN.DOCUMENTS.FORM.URL.HELP_TEXT')
);

const getErrorMessage = (field, errorKey) => {
  return v$.value[field].$error
    ? t(`CAPTAIN.DOCUMENTS.FORM.${errorKey}.ERROR`)
    : '';
};

const formErrors = computed(() => ({
  url: getErrorMessage('url', 'URL'),
  pdfFile: getErrorMessage('pdfFile', 'PDF_FILE'),
}));

const handleCancel = () => emit('cancel');

const handleFileChange = event => {
  const file = event.target.files[0];
  if (file) {
    if (file.type !== 'application/pdf') {
      useAlert(t('CAPTAIN.DOCUMENTS.FORM.PDF_FILE.INVALID_TYPE'));
      event.target.value = '';
      return;
    }
    if (file.size > MAX_FILE_SIZE) {
      // 10MB
      useAlert(t('CAPTAIN.DOCUMENTS.FORM.PDF_FILE.TOO_LARGE'));
      event.target.value = '';
      return;
    }
    state.pdfFile = file;
    state.name = file.name.replace(/\.pdf$/i, '');
  }
};

const openFileDialog = () => {
  // Use nextTick to ensure the ref is available
  nextTick(() => {
    if (fileInputRef.value) {
      fileInputRef.value.click();
    }
  });
};

const prepareDocumentDetails = () => {
  const formData = new FormData();
  formData.append('document[assistant_id]', props.assistantId);

  if (state.documentType === 'web') {
    formData.append('document[external_link]', state.url);
    formData.append('document[name]', state.name || state.url);
    formData.append('document[metadata][crawl_mode]', 'website');
    formData.append('document[metadata][crawl_root_url]', state.url);
    formData.append('document[metadata][crawl_depth]', String(state.crawlDepth));
  } else {
    formData.append('document[pdf_file]', state.pdfFile);
    formData.append(
      'document[name]',
      state.name || state.pdfFile.name.replace('.pdf', '')
    );
    // No need to send external_link for PDF - it's auto-generated in the backend
  }

  return formData;
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) {
    return;
  }

  emit('submit', prepareDocumentDetails());
};
</script>

<template>
  <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
    <div
      class="rounded-xl border border-n-weak bg-n-slate-2/60 p-4 text-sm text-n-slate-11"
    >
      <p class="m-0 text-base font-medium text-n-slate-12">
        {{ t('CAPTAIN.DOCUMENTS.FORM.HELP_PANEL.TITLE') }}
      </p>
      <p class="mt-1 mb-0">
        {{ t('CAPTAIN.DOCUMENTS.FORM.HELP_PANEL.SUBTITLE') }}
      </p>
      <div class="mt-4 grid gap-2 sm:grid-cols-3">
        <div class="rounded-lg bg-n-alpha-2 px-3 py-2">
          <p class="m-0 text-[11px] font-semibold uppercase tracking-[0.18em] text-n-slate-11">
            01
          </p>
          <p class="mt-1 mb-0 text-sm text-n-slate-12">
            {{ t('CAPTAIN.DOCUMENTS.FORM.HELP_PANEL.STEP_ONE') }}
          </p>
        </div>
        <div class="rounded-lg bg-n-alpha-2 px-3 py-2">
          <p class="m-0 text-[11px] font-semibold uppercase tracking-[0.18em] text-n-slate-11">
            02
          </p>
          <p class="mt-1 mb-0 text-sm text-n-slate-12">
            {{ t('CAPTAIN.DOCUMENTS.FORM.HELP_PANEL.STEP_TWO') }}
          </p>
        </div>
        <div class="rounded-lg bg-n-alpha-2 px-3 py-2">
          <p class="m-0 text-[11px] font-semibold uppercase tracking-[0.18em] text-n-slate-11">
            03
          </p>
          <p class="mt-1 mb-0 text-sm text-n-slate-12">
            {{ t('CAPTAIN.DOCUMENTS.FORM.HELP_PANEL.STEP_THREE') }}
          </p>
        </div>
      </div>
    </div>

    <div class="flex flex-col gap-1">
      <label
        for="documentType"
        class="mb-0.5 text-sm font-medium text-n-slate-12"
      >
        {{ t('CAPTAIN.DOCUMENTS.FORM.TYPE.LABEL') }}
      </label>
      <ComboBox
        id="documentType"
        v-model="state.documentType"
        :options="documentTypeOptions"
        class="[&>div>button]:bg-n-alpha-black2"
      />
    </div>

    <Input
      v-if="state.documentType === 'web'"
      v-model="state.url"
      :label="t('CAPTAIN.DOCUMENTS.FORM.URL.LABEL')"
      :placeholder="t('CAPTAIN.DOCUMENTS.FORM.URL.PLACEHOLDER')"
      :message="formErrors.url || webUrlHelpText"
      :message-type="formErrors.url ? 'error' : 'info'"
    />

    <Input
      v-if="state.documentType === 'web'"
      v-model="state.crawlDepth"
      type="number"
      min="1"
      max="250"
      :label="t('CAPTAIN.DOCUMENTS.FORM.CRAWL_LIMIT.LABEL')"
      :placeholder="t('CAPTAIN.DOCUMENTS.FORM.CRAWL_LIMIT.PLACEHOLDER')"
      :message="t('CAPTAIN.DOCUMENTS.FORM.CRAWL_LIMIT.HELP_TEXT')"
    />

    <div v-if="state.documentType === 'pdf'" class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.DOCUMENTS.FORM.PDF_FILE.LABEL') }}
      </label>
      <div class="relative">
        <input
          ref="fileInputRef"
          type="file"
          accept=".pdf"
          class="hidden"
          @change="handleFileChange"
        />
        <Button
          type="button"
          :color="hasPdfFileError ? 'ruby' : 'slate'"
          :variant="hasPdfFileError ? 'outline' : 'solid'"
          class="!w-full !h-auto !justify-between !py-4"
          @click="openFileDialog"
        >
          <template #default>
            <div class="flex gap-2 items-center">
              <div
                class="flex justify-center items-center w-10 h-10 rounded-lg bg-n-slate-3"
              >
                <i class="text-xl i-ph-file-pdf text-n-slate-11" />
              </div>
              <div class="flex flex-col flex-1 gap-1 items-start">
                <p class="m-0 text-sm font-medium text-n-slate-12">
                  {{
                    state.pdfFile
                      ? state.pdfFile.name
                      : t('CAPTAIN.DOCUMENTS.FORM.PDF_FILE.CHOOSE_FILE')
                  }}
                </p>
                <p class="m-0 text-xs text-n-slate-11">
                  {{
                    state.pdfFile
                      ? `${(state.pdfFile.size / 1024 / 1024).toFixed(2)} MB`
                      : t('CAPTAIN.DOCUMENTS.FORM.PDF_FILE.HELP_TEXT')
                  }}
                </p>
              </div>
            </div>

            <i class="i-lucide-upload text-n-slate-11" />
          </template>
        </Button>
      </div>
      <p v-if="formErrors.pdfFile" class="text-xs text-n-ruby-9">
        {{ formErrors.pdfFile }}
      </p>
    </div>

    <Input
      v-model="state.name"
      :label="t('CAPTAIN.DOCUMENTS.FORM.NAME.LABEL')"
      :placeholder="t('CAPTAIN.DOCUMENTS.FORM.NAME.PLACEHOLDER')"
    />

    <div class="flex gap-3 justify-between items-center w-full">
      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAPTAIN.FORM.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        type="submit"
        :label="t('CAPTAIN.FORM.CREATE')"
        class="w-full"
        :is-loading="isLoading"
        :disabled="isLoading"
      />
    </div>
  </form>
</template>
