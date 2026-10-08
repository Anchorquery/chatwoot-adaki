<script setup>
import { ref } from 'vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import EvolutionConnection from 'dashboard/routes/dashboard/settings/inbox/components/EvolutionConnection.vue';

const emit = defineEmits(['closed']);

const dialogRef = ref(null);
const inbox = ref(null);

const open = target => {
  inbox.value = target;
  dialogRef.value?.open();
};

// El contenido solo vive mientras el diálogo está abierto: al cerrarlo se
// desmonta EvolutionConnection y su sondeo se detiene.
const onClose = () => emit('closed', inbox.value);

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    overflow-y-auto
    :title="inbox?.name || ''"
    :description="$t('WHATSAPP_CONNECTIONS.QR_DIALOG.DESCRIPTION')"
    :show-confirm-button="false"
    :cancel-button-label="$t('WHATSAPP_CONNECTIONS.QR_DIALOG.CLOSE')"
    @close="onClose"
  >
    <EvolutionConnection
      v-if="inbox"
      :key="inbox.id"
      :inbox-id="inbox.id"
      auto-connect
    />
  </Dialog>
</template>
