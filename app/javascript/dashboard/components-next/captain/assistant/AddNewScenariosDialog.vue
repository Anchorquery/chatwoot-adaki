<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useRoute } from 'vue-router';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import CaptainScenariosAPI from 'dashboard/api/captain/scenarios';
import { useAlert } from 'dashboard/composables';

const emit = defineEmits(['add']);

const { t } = useI18n();
const route = useRoute();

const dialogRef = ref(null);
const aiPrompt = ref('');
const isGenerating = ref(false);

const assistantId = computed(() => Number(route.params.assistantId));

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
  aiPrompt.value = '';
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

const onGenerateWithAI = async () => {
  if (!aiPrompt.value.trim()) return;

  isGenerating.value = true;
  try {
    const { data } = await CaptainScenariosAPI.generate({
      assistantId: assistantId.value,
      prompt: aiPrompt.value.trim(),
    });
    state.title = data.title || '';
    state.description = data.description || '';
    state.instruction = data.instruction || '';
    v$.value.$reset();
  } catch {
    useAlert(t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.ERROR'));
  } finally {
    isGenerating.value = false;
  }
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
      <!-- AI Generation Section -->
      <div class="mb-6 p-4 rounded-xl bg-n-alpha-1 border border-n-strong/10">
        <p class="text-sm font-medium text-n-slate-12 mb-3">
          {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.LABEL') }}
        </p>
        <div class="flex gap-2">
          <div class="flex-1">
            <Input
              v-model="aiPrompt"
              :placeholder="
                t(
                  'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.PLACEHOLDER'
                )
              "
              @keyup.enter="onGenerateWithAI"
            />
          </div>
          <Button
            :label="
              isGenerating
                ? t(
                    'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.GENERATING'
                  )
                : t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.BUTTON')
            "
            :is-loading="isGenerating"
            :disabled="!aiPrompt.trim() || isGenerating"
            icon="i-lucide-sparkles"
            type="button"
            @click="onGenerateWithAI"
          />
        </div>
      </div>

      <!-- Divider -->
      <div class="flex items-center gap-3 mb-6">
        <div class="flex-1 h-px bg-n-strong/10" />
        <span class="text-xs text-n-slate-10">
          {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.AI_GENERATE.DIVIDER') }}
        </span>
        <div class="flex-1 h-px bg-n-strong/10" />
      </div>

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
