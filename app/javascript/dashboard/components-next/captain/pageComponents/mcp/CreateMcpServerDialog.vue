<script setup>
import { ref, computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import McpServerForm from './McpServerForm.vue';

const props = defineProps({
  selectedServer: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
});

const emit = defineEmits(['close']);
const { t } = useI18n();
const store = useStore();
const dialogRef = ref(null);
const formRef = ref(null);

const i18nKey = computed(() => `CAPTAIN.MCP.${props.type.toUpperCase()}`);

const handleSubmit = async serverDetails => {
  try {
    if (props.type === 'edit') {
      await store.dispatch('captainMcpServers/update', {
        id: props.selectedServer.id,
        ...serverDetails,
      });
    } else {
      await store.dispatch('captainMcpServers/create', serverDetails);
    }
    useAlert(t(`${i18nKey.value}.SUCCESS_MESSAGE`));
    dialogRef.value.close();
  } catch (error) {
    useAlert(parseAPIErrorResponse(error) || t(`${i18nKey.value}.ERROR_MESSAGE`));
  }
};

const handleClose = () => emit('close');

const handleFormClose = () => {
  dialogRef.value?.close();
};

defineExpose({ dialogRef, formRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="3xl"
    :title="$t(`${i18nKey}.TITLE`)"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <McpServerForm
      ref="formRef"
      :mode="type"
      :server="selectedServer"
      @close="handleFormClose"
      @submit="handleSubmit"
    />
    <template #footer />
  </Dialog>
</template>
