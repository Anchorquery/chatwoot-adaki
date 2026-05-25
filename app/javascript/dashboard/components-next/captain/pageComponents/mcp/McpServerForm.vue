<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, requiredIf, maxLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import PlatformCredentialsAPI from 'dashboard/api/platform/credentials';

import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
  server: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['close', 'submit']);

const { t } = useI18n();
const dialogRef = ref(null);
const credentials = ref([]);

const initialState = {
  name: '',
  description: '',
  transport_type: 'streamable_http',
  endpoint_url: '',
  command: '',
  command_args: [],
  platform_credential_id: '',
  timeout_seconds: 20,
  enabled: true,
};

const state = reactive({ ...initialState });

const isHttpTransport = computed(() => state.transport_type === 'streamable_http');

const validationRules = computed(() => ({
  name: { required, maxLength: maxLength(120) },
  endpoint_url: { required: requiredIf(() => isHttpTransport.value) },
  command: { required: requiredIf(() => !isHttpTransport.value) },
}));

const v$ = useVuelidate(validationRules, state);

const credentialOptions = computed(() => [
  { value: '', label: t('CAPTAIN.MCP.FORM.NO_CREDENTIAL') },
  ...credentials.value.map(credential => ({
    value: credential.id,
    label: `${credential.name} (${credential.provider})`,
  })),
]);

const resetForm = () => {
  Object.assign(state, {
    ...initialState,
    platform_credential_id: '',
  });
};

const populateForm = server => {
  Object.assign(state, {
    name: server.name || '',
    description: server.description || '',
    transport_type: server.transport_type || 'streamable_http',
    endpoint_url: server.endpoint_url || '',
    command: server.command || '',
    command_args: server.command_args || [],
    platform_credential_id: server.platform_credential_id || '',
    timeout_seconds: server.timeout_seconds || 20,
    enabled: server.enabled ?? true,
  });
};

const fetchCredentials = async () => {
  try {
    const { data } = await PlatformCredentialsAPI.index();
    credentials.value = data;
  } catch (error) {
    useAlert(parseAPIErrorResponse(error) || t('CAPTAIN.MCP.ALERTS.ERROR'));
  }
};

const handleSubmit = async () => {
  const isValid = await v$.value.$validate();
  if (!isValid) return;

  emit('submit', {
    ...state,
    platform_credential_id: state.platform_credential_id
      ? Number(state.platform_credential_id)
      : null,
  });
};

const handleClose = () => {
  emit('close');
};

defineExpose({ dialogRef, resetForm, populateForm });

onMounted(() => {
  fetchCredentials();
  if (props.mode === 'edit' && props.server?.id) {
    populateForm(props.server);
  }
});
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    :title="mode === 'edit' ? $t('CAPTAIN.MCP.FORM.EDIT_TITLE') : $t('CAPTAIN.MCP.FORM.NEW_TITLE')"
    :description="$t('CAPTAIN.MCP.FORM.DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
      <Input
        v-model="state.name"
        :label="$t('CAPTAIN.MCP.FORM.NAME')"
        :message="v$.name.$error ? $t('CAPTAIN.MCP.FORM.ERRORS.NAME') : ''"
        :message-type="v$.name.$error ? 'error' : 'info'"
      />
      <TextArea
        v-model="state.description"
        :label="$t('CAPTAIN.MCP.FORM.DESCRIPTION_LABEL')"
        :rows="2"
      />
      <Input
        v-model="state.endpoint_url"
        :label="$t('CAPTAIN.MCP.FORM.ENDPOINT_URL')"
        :message="v$.endpoint_url.$error ? $t('CAPTAIN.MCP.FORM.ERRORS.ENDPOINT_URL') : ''"
        :message-type="v$.endpoint_url.$error ? 'error' : 'info'"
      />
      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Input
          v-model="state.timeout_seconds"
          type="number"
          min="1"
          :label="$t('CAPTAIN.MCP.FORM.TIMEOUT')"
        />
        <div class="flex flex-col gap-1">
          <label class="text-sm text-n-slate-12">
            {{ $t('CAPTAIN.MCP.FORM.CREDENTIAL') }}
          </label>
          <ComboBox
            v-model="state.platform_credential_id"
            :options="credentialOptions"
            :placeholder="$t('CAPTAIN.MCP.FORM.CREDENTIAL_PLACEHOLDER')"
          />
        </div>
      </div>

      <label class="flex items-center gap-2 text-sm text-n-slate-12">
        <input
          v-model="state.enabled"
          type="checkbox"
          class="rounded border-n-weak text-n-brand focus:ring-n-brand"
        />
        {{ $t('CAPTAIN.MCP.FORM.ENABLED') }}
      </label>

      <div class="flex items-center justify-end gap-2 pt-2">
        <Button
          type="button"
          ghost
          color="slate"
          :label="$t('CAPTAIN.MCP.FORM.CANCEL')"
          @click="handleClose"
        />
        <Button
          type="submit"
          color="blue"
          :is-loading="false"
          :label="mode === 'edit' ? $t('CAPTAIN.MCP.FORM.SAVE') : $t('CAPTAIN.MCP.FORM.CREATE')"
        />
      </div>
    </form>
  </Dialog>
</template>
