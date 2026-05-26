<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';

import { useAlert } from 'dashboard/composables';
import CaptainScenariosAPI from 'dashboard/api/captain/scenarios';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

const props = defineProps({
  referenceScenarios: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['add']);

const { t } = useI18n();
const route = useRoute();

const dialogRef = ref(null);
const isGenerating = ref('');

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

const assistantId = computed(() => Number(route.params.assistantId));

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
  isGenerating.value = '';
  v$.value.$reset();
};

const generateField = async focus => {
  if (!assistantId.value || isGenerating.value) return;

  try {
    isGenerating.value = focus;
    const { data } = await CaptainScenariosAPI.generate(
      { assistantId: assistantId.value },
      {
        focus,
        reference_scenarios: props.referenceScenarios,
      }
    );

    const generatedValue = data?.value?.trim();
    if (!generatedValue) {
      throw new Error('Empty AI response');
    }

    state[focus] = generatedValue;
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.GENERATE.ERROR')
    );
  } finally {
    isGenerating.value = '';
  }
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
          <div class="flex flex-col gap-1">
            <div class="flex items-center justify-between gap-3">
              <label class="text-sm font-medium text-n-slate-12">
                {{ t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.LABEL') }}
              </label>
              <Button
                :label="
                  t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.GENERATE_TITLE')
                "
                :is-loading="isGenerating === 'title'"
                ghost
                xs
                slate
                class="shrink-0 !text-xs"
                icon="i-lucide-sparkles"
                @click="generateField('title')"
              />
            </div>
            <Input
              v-model="state.title"
              :placeholder="
                t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.TITLE.PLACEHOLDER')
              "
              :message="titleError"
              :message-type="titleError ? 'error' : 'info'"
            />
          </div>

          <div class="flex flex-col gap-1">
            <div class="flex items-center justify-between gap-3">
              <label class="text-sm font-medium text-n-slate-12">
                {{
                  t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.DESCRIPTION.LABEL')
                }}
              </label>
              <Button
                :label="
                  t(
                    'CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.GENERATE_DESCRIPTION'
                  )
                "
                :is-loading="isGenerating === 'description'"
                ghost
                xs
                slate
                class="shrink-0 !text-xs"
                icon="i-lucide-sparkles"
                @click="generateField('description')"
              />
            </div>
            <TextArea
              v-model="state.description"
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
        </div>

        <div class="flex flex-col gap-1">
          <div class="flex items-center justify-between gap-3">
            <label class="text-sm font-medium text-n-slate-12">
              {{
                t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.INSTRUCTION.LABEL')
              }}
            </label>
            <Button
              :label="
                t('CAPTAIN.ASSISTANTS.SCENARIOS.ADD.NEW.FORM.GENERATE_INSTRUCTION')
              "
              :is-loading="isGenerating === 'instruction'"
              ghost
              xs
              slate
              class="shrink-0 !text-xs"
              icon="i-lucide-sparkles"
              @click="generateField('instruction')"
            />
          </div>
          <Editor
            v-model="state.instruction"
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
