<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { minLength } from '@vuelidate/validators';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['submit']);

const { t } = useI18n();
const { isCloudFeatureEnabled } = useAccount();

const isCaptainV2Enabled = computed(() =>
  isCloudFeatureEnabled(FEATURE_FLAGS.CAPTAIN_V2)
);

const HUMAN_TAKEOVER_MODES = ['always', 'after_window', 'never'];
const REASONING_LEVELS = ['off', 'low', 'dynamic'];

// Teams are loaded account-wide at dashboard boot (see teams store module).
const teams = useMapGetter('teams/getTeams');

const initialState = {
  handoffMessage: '',
  resolutionMessage: '',
  instructions: '',
  temperature: 1,
  autopilotEnabled: false,
  continueAfterHumanTakeover: true,
  humanTakeoverMode: 'after_window',
  humanTakeoverWindowMinutes: 15,
  autoHandoffEnabled: false,
  autoResolveHours: 24,
  handoffTeamId: null,
  reasoningLevel: 'off',
};

const state = reactive({ ...initialState });

const validationRules = {
  handoffMessage: { minLength: minLength(1) },
  resolutionMessage: { minLength: minLength(1) },
  instructions: { minLength: minLength(1) },
};

const v$ = useVuelidate(validationRules, state);

const getErrorMessage = field => {
  return v$.value[field].$error ? v$.value[field].$errors[0].$message : '';
};

const formErrors = computed(() => ({
  handoffMessage: getErrorMessage('handoffMessage'),
  resolutionMessage: getErrorMessage('resolutionMessage'),
  instructions: getErrorMessage('instructions'),
}));

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.handoffMessage = config.handoff_message;
  state.resolutionMessage = config.resolution_message;
  state.instructions = config.instructions;
  state.temperature = config.temperature || 1;
  state.autopilotEnabled = config.autopilot_enabled || false;
  state.continueAfterHumanTakeover =
    config.continue_after_human_takeover === undefined
      ? true
      : !!config.continue_after_human_takeover;
  state.autoHandoffEnabled = !!config.auto_handoff_enabled;
  state.autoResolveHours = Number(config.auto_resolve_hours) || 24;
  state.humanTakeoverMode = HUMAN_TAKEOVER_MODES.includes(
    config.human_takeover_mode
  )
    ? config.human_takeover_mode
    : 'after_window';
  state.humanTakeoverWindowMinutes =
    Number(config.human_takeover_window_minutes) || 15;
  state.handoffTeamId = Number(config.handoff_team_id) || null;
  state.reasoningLevel = REASONING_LEVELS.includes(config.reasoning_level)
    ? config.reasoning_level
    : 'off';
};

const handleSystemMessagesUpdate = async () => {
  const validations = [
    v$.value.handoffMessage.$validate(),
    v$.value.resolutionMessage.$validate(),
  ];

  if (!isCaptainV2Enabled.value) {
    validations.push(v$.value.instructions.$validate());
  }

  const result = await Promise.all(validations).then(results =>
    results.every(Boolean)
  );
  if (!result) return;

  const payload = {
    config: {
      ...props.assistant.config,
      handoff_message: state.handoffMessage,
      resolution_message: state.resolutionMessage,
      temperature: state.temperature || 1,
      autopilot_enabled: state.autopilotEnabled,
      continue_after_human_takeover: state.continueAfterHumanTakeover,
      human_takeover_mode: state.humanTakeoverMode,
      human_takeover_window_minutes:
        Number(state.humanTakeoverWindowMinutes) || 15,
      auto_handoff_enabled: state.autoHandoffEnabled,
      auto_resolve_hours: Number(state.autoResolveHours) || 24,
      handoff_team_id: Number(state.handoffTeamId) || null,
      reasoning_level: state.reasoningLevel,
    },
  };

  if (!isCaptainV2Enabled.value) {
    payload.config.instructions = state.instructions;
  }

  emit('submit', payload);
};

watch(
  () => props.assistant,
  newAssistant => {
    if (newAssistant) updateStateFromAssistant(newAssistant);
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-6">
    <div class="rounded-2xl border border-n-weak bg-n-alpha-black2 p-4">
      <p class="text-sm font-medium text-n-slate-12">
        {{
          t('CAPTAIN.ASSISTANTS.SETTINGS.SYSTEM_SETTINGS.ADVANCED_HINT.TITLE')
        }}
      </p>
      <p class="mt-1 text-sm leading-6 text-n-slate-11">
        {{
          t(
            'CAPTAIN.ASSISTANTS.SETTINGS.SYSTEM_SETTINGS.ADVANCED_HINT.DESCRIPTION'
          )
        }}
      </p>
    </div>

    <Editor
      v-model="state.handoffMessage"
      :label="t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_MESSAGE.PLACEHOLDER')"
      :message="formErrors.handoffMessage"
      :message-type="formErrors.handoffMessage ? 'error' : 'info'"
      class="z-0"
    />

    <Editor
      v-model="state.resolutionMessage"
      :label="t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.RESOLUTION_MESSAGE.PLACEHOLDER')"
      :message="formErrors.resolutionMessage"
      :message-type="formErrors.resolutionMessage ? 'error' : 'info'"
      class="z-0"
    />

    <Editor
      v-if="!isCaptainV2Enabled"
      v-model="state.instructions"
      :label="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTIONS.LABEL')"
      :placeholder="t('CAPTAIN.ASSISTANTS.FORM.INSTRUCTIONS.PLACEHOLDER')"
      :message="formErrors.instructions"
      :max-length="20000"
      :message-type="formErrors.instructions ? 'error' : 'info'"
      class="z-0"
    />

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.LABEL') }}
      </label>
      <div class="flex items-center gap-4">
        <input
          v-model="state.temperature"
          type="range"
          min="0"
          max="1"
          step="0.1"
          class="w-full"
        />
        <span class="text-sm text-n-slate-12">{{ state.temperature }}</span>
      </div>
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.TEMPERATURE.DESCRIPTION') }}
      </p>
    </div>

    <SettingsToggleSection
      v-model="state.autopilotEnabled"
      :header="t('CAPTAIN.ASSISTANTS.FORM.AUTOPILOT.LABEL')"
      :description="t('CAPTAIN.ASSISTANTS.FORM.AUTOPILOT.DESCRIPTION')"
    />

    <SettingsToggleSection
      v-if="!isCaptainV2Enabled"
      v-model="state.continueAfterHumanTakeover"
      :header="t('CAPTAIN.ASSISTANTS.FORM.CONTINUE_AFTER_TAKEOVER.LABEL')"
      :description="
        t('CAPTAIN.ASSISTANTS.FORM.CONTINUE_AFTER_TAKEOVER.DESCRIPTION')
      "
    />

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.LABEL') }}
      </label>
      <select
        v-model="state.humanTakeoverMode"
        class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-alpha-black2 text-sm text-n-slate-12"
      >
        <option value="always">
          {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.ALWAYS') }}
        </option>
        <option value="after_window">
          {{
            t(
              'CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.AFTER_WINDOW'
            )
          }}
        </option>
        <option value="never">
          {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.NEVER') }}
        </option>
      </select>
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.DESCRIPTION') }}
      </p>
    </div>

    <div
      v-if="state.humanTakeoverMode === 'after_window'"
      class="flex flex-col gap-2"
    >
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_WINDOW.LABEL') }}
      </label>
      <input
        v-model.number="state.humanTakeoverWindowMinutes"
        type="number"
        min="1"
        max="10080"
        class="w-32 px-3 py-2 rounded-lg border border-n-weak bg-n-alpha-black2 text-sm text-n-slate-12"
      />
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_WINDOW.DESCRIPTION') }}
      </p>
    </div>

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.REASONING_LEVEL.LABEL') }}
      </label>
      <select
        v-model="state.reasoningLevel"
        class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-alpha-black2 text-sm text-n-slate-12"
      >
        <option value="off">
          {{ t('CAPTAIN.ASSISTANTS.FORM.REASONING_LEVEL.OPTIONS.OFF') }}
        </option>
        <option value="low">
          {{ t('CAPTAIN.ASSISTANTS.FORM.REASONING_LEVEL.OPTIONS.LOW') }}
        </option>
        <option value="dynamic">
          {{ t('CAPTAIN.ASSISTANTS.FORM.REASONING_LEVEL.OPTIONS.DYNAMIC') }}
        </option>
      </select>
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.REASONING_LEVEL.DESCRIPTION') }}
      </p>
    </div>

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.LABEL') }}
      </label>
      <select
        v-model="state.handoffTeamId"
        class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-alpha-black2 text-sm text-n-slate-12"
      >
        <option :value="null">
          {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.NONE') }}
        </option>
        <option v-for="team in teams" :key="team.id" :value="team.id">
          {{ team.name }}
        </option>
      </select>
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.DESCRIPTION') }}
      </p>
    </div>

    <SettingsToggleSection
      v-model="state.autoHandoffEnabled"
      :header="t('CAPTAIN.ASSISTANTS.FORM.AUTO_HANDOFF.LABEL')"
      :description="t('CAPTAIN.ASSISTANTS.FORM.AUTO_HANDOFF.DESCRIPTION')"
    />

    <div v-if="state.autoHandoffEnabled" class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_RESOLVE_HOURS.LABEL') }}
      </label>
      <input
        v-model.number="state.autoResolveHours"
        type="number"
        min="1"
        max="720"
        class="w-32 px-3 py-2 rounded-lg border border-n-weak bg-n-alpha-black2 text-sm text-n-slate-12"
      />
      <p class="text-sm text-n-slate-11 italic">
        {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_RESOLVE_HOURS.DESCRIPTION') }}
      </p>
    </div>

    <div>
      <Button
        :label="t('CAPTAIN.ASSISTANTS.FORM.UPDATE')"
        @click="handleSystemMessagesUpdate"
      />
    </div>
  </div>
</template>
