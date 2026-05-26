<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

const emit = defineEmits(['add']);

const { t } = useI18n();

const dialogRef = ref(null);

const state = reactive({
  id: '',
  title: '',
  description: '',
  instruction: '',
});

const rules = {
  title: { required, minLength: minLength(1) },
  description: { required },
  instruction: { required },
};

const v$ = useVuelidate(rules, state);

const titleError = computed(() =>
  v$.value.title.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.ERROR')
    : ''
);

const descriptionError = computed(() =>
  v$.value.description.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.ERROR')
    : ''
);

const instructionError = computed(() =>
  v$.value.instruction.$error
    ? t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.ERROR')
    : ''
);

const resetState = () => {
  Object.assign(state, {
    id: '',
    title: '',
    description: '',
    instruction: '',
  });
  v$.value.$reset();
};

const openDialog = () => {
  dialogRef.value?.open();
};

const onClickAdd = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  emit('add', { ...state });
  dialogRef.value?.close();
};

const onClickCancel = () => {
  dialogRef.value?.close();
};
</script>

<template>
  <div class="inline-flex relative">
    <Button
      :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.CREATE')"
      sm
      slate
      class="flex-shrink-0"
      @click="openDialog"
    />

    <Dialog
      ref="dialogRef"
      type="edit"
      :title="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.TITLE')"
      width="5xl"
      overflow-y-auto
      :show-cancel-button="false"
      :show-confirm-button="false"
      @close="resetState"
    >
      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
        <div class="flex flex-col gap-4">
          <Input
            v-model="state.title"
            :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.LABEL')"
            :placeholder="
              t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.PLACEHOLDER')
            "
            :message="titleError"
            :message-type="titleError ? 'error' : 'info'"
          />

          <TextArea
            v-model="state.description"
            :label="
              t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.LABEL')
            "
            :placeholder="
              t(
                'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.PLACEHOLDER'
              )
            "
            :message="descriptionError"
            :message-type="descriptionError ? 'error' : 'info'"
            show-character-count
          />
        </div>

        <Editor
          v-model="state.instruction"
          :label="
            t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.LABEL')
          "
          :placeholder="
            t(
              'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.PLACEHOLDER'
            )
          "
          :message="instructionError"
          :message-type="instructionError ? 'error' : 'info'"
          :show-character-count="false"
          enable-captain-tools
        />
      </div>

      <div class="mt-6 flex items-center justify-end gap-3">
        <Button
          variant="faded"
          color="slate"
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.CANCEL')"
          class="bg-n-alpha-2 !text-n-blue-11 hover:bg-n-alpha-3"
          type="button"
          @click="onClickCancel"
        />
        <Button
          :label="t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.CREATE')"
          type="button"
          @click="onClickAdd"
        />
      </div>
    </Dialog>
  </div>
</template>
