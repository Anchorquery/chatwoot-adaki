<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { helpers, required } from '@vuelidate/validators';
import { isDomain } from 'shared/helpers/Validators';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

defineProps({
  isLoading: { type: Boolean, default: false },
});

const emit = defineEmits(['create']);

const { t } = useI18n();
const dialogRef = ref(null);

const form = reactive({ name: '', domain: '', description: '' });

const domainFormat = value => isDomain(value.trim());

const rules = {
  name: {
    required: helpers.withMessage(
      () => t('COMPANIES.CREATE.FIELDS.NAME.ERROR'),
      required
    ),
  },
  domain: {
    domainFormat: helpers.withMessage(
      () => t('COMPANIES.CREATE.FIELDS.DOMAIN.ERROR'),
      domainFormat
    ),
  },
};

const v$ = useVuelidate(rules, form);

const nameError = computed(() =>
  v$.value.name.$error ? t('COMPANIES.CREATE.FIELDS.NAME.ERROR') : ''
);

const domainError = computed(() =>
  v$.value.domain.$error ? v$.value.domain.$errors[0]?.$message : ''
);

const domainMessage = computed(() =>
  domainError.value || t('COMPANIES.CREATE.FIELDS.DOMAIN.MESSAGE')
);

const isFormInvalid = computed(() => v$.value.$invalid);

const resetForm = () => {
  form.name = '';
  form.domain = '';
  form.description = '';
  v$.value.$reset();
};

const handleConfirm = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  emit('create', {
    name: form.name.trim(),
    domain: form.domain.trim() || null,
    description: form.description.trim() || null,
  });
};

const closeDialog = () => {
  dialogRef.value?.close();
};

const onSuccess = () => {
  resetForm();
  closeDialog();
};

defineExpose({ dialogRef, onSuccess });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="3xl"
    overflow-y-auto
    @confirm="handleConfirm"
    @close="resetForm"
  >
    <div class="flex flex-col gap-6">
      <div class="flex flex-col items-start gap-2">
        <span class="py-1 text-sm font-medium text-n-slate-12">
          {{ t('COMPANIES.CREATE.TITLE') }}
        </span>
        <p class="text-sm leading-5 text-n-slate-11">
          {{ t('COMPANIES.CREATE.DESCRIPTION') }}
        </p>
        <div class="grid w-full grid-cols-1 gap-4 sm:grid-cols-2">
          <Input
            id="company-name"
            v-model="form.name"
            :placeholder="t('COMPANIES.DETAIL.PROFILE.FIELDS.NAME')"
            :label="t('COMPANIES.DETAIL.PROFILE.FIELDS.NAME')"
            :message="nameError"
            :message-type="nameError ? 'error' : 'info'"
            :disabled="isLoading"
            custom-input-class="h-8 !pt-1 !pb-1 [&:not(.error,.focus)]:!outline-transparent"
            autofocus
            @blur="v$.name.$touch()"
          />
          <Input
            id="company-domain"
            v-model="form.domain"
            :placeholder="t('COMPANIES.DETAIL.PROFILE.FIELDS.DOMAIN')"
            :label="t('COMPANIES.DETAIL.PROFILE.FIELDS.DOMAIN')"
            :message="domainMessage"
            :message-type="domainError ? 'error' : 'info'"
            :disabled="isLoading"
            custom-input-class="h-8 !pt-1 !pb-1 [&:not(.error,.focus)]:!outline-transparent"
            @blur="v$.domain.$touch()"
            @input="v$.domain.$touch()"
          />
        </div>
      </div>
      <TextArea
        v-model="form.description"
        :placeholder="t('COMPANIES.DETAIL.PROFILE.DESCRIPTION_PLACEHOLDER')"
        :disabled="isLoading"
        :max-length="280"
        class="w-full"
        show-character-count
        auto-height
      />
    </div>

    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          :label="t('DIALOG.BUTTONS.CANCEL')"
          variant="link"
          type="reset"
          class="h-10 hover:!no-underline hover:text-n-brand"
          @click="closeDialog"
        />
        <Button
          :label="t('COMPANIES.CREATE.ACTIONS.SAVE')"
          color="blue"
          type="submit"
          :disabled="isFormInvalid || isLoading"
          :is-loading="isLoading"
        />
      </div>
    </template>
  </Dialog>
</template>
