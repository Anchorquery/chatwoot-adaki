<script setup>
import { ref, reactive } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import CaptainAssistantAPI from 'dashboard/api/captain/assistant';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  assistant: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['generated']);

const { t } = useI18n();

const isLoading = ref(false);

const fields = reactive({
  description: true,
  response_guidelines: true,
  guardrails: true,
  handoff_message: true,
  resolution_message: true,
  scenarios: true,
});

const FIELD_KEYS = Object.keys(fields);

const generateConfig = async () => {
  const selectedFields = FIELD_KEYS.filter(k => fields[k]);
  if (!selectedFields.length) return;

  isLoading.value = true;
  try {
    const { data } = await CaptainAssistantAPI.generateConfig(
      props.assistant.id,
      selectedFields
    );
    emit('generated', data);
    useAlert(t('CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        t('CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.ERROR')
    );
  } finally {
    isLoading.value = false;
  }
};
</script>

<template>
  <div class="rounded-2xl border border-n-strong bg-n-alpha-2 p-4 flex flex-col gap-4">
    <div>
      <p class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.TITLE') }}
      </p>
      <p class="mt-1 text-sm leading-5 text-n-slate-11">
        {{ t('CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.DESCRIPTION') }}
      </p>
    </div>

    <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
      <label
        v-for="key in FIELD_KEYS"
        :key="key"
        class="flex items-center gap-2 text-sm text-n-slate-11 cursor-pointer"
      >
        <input v-model="fields[key]" type="checkbox" class="rounded" />
        {{ t(`CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.FIELDS.${key}`) }}
      </label>
    </div>

    <div>
      <Button
        :label="t('CAPTAIN.ASSISTANTS.SETTINGS.AI_CONFIG_PANEL.BUTTON')"
        :is-loading="isLoading"
        :disabled="isLoading || !FIELD_KEYS.some(k => fields[k])"
        icon="i-lucide-sparkles"
        @click="generateConfig"
      />
    </div>
  </div>
</template>
