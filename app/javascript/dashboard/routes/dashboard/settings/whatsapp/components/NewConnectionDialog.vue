<script setup>
import { ref, computed, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import EvolutionConnection from 'dashboard/routes/dashboard/settings/inbox/components/EvolutionConnection.vue';

const emit = defineEmits(['created', 'connected', 'closed']);

const { t } = useI18n();
const router = useRouter();
const store = useStore();

const dialogRef = ref(null);
const nameInput = ref(null);
const name = ref('');
const nameError = ref('');
const creating = ref(false);
const createdInbox = ref(null);

const CREATE_ERRORS = {
  name_taken: 'NAME_TAKEN',
  not_configured: 'NOT_CONFIGURED',
  name_required: 'NAME_REQUIRED',
};

const title = computed(() =>
  createdInbox.value
    ? t('WHATSAPP_CONNECTIONS.NEW.SCAN_TITLE', {
        name: createdInbox.value.name,
      })
    : t('WHATSAPP_CONNECTIONS.NEW.TITLE')
);

const open = async () => {
  name.value = '';
  nameError.value = '';
  createdInbox.value = null;
  dialogRef.value?.open();
  await nextTick();
  nameInput.value?.focus();
};

const create = async () => {
  if (createdInbox.value) return;
  const trimmed = name.value.trim();
  if (!trimmed) {
    nameError.value = t('INBOX_MGMT.ADD.EVOLUTION.ERRORS.NAME_REQUIRED');
    return;
  }
  nameError.value = '';
  creating.value = true;
  try {
    createdInbox.value = await store.dispatch(
      'inboxes/createEvolutionChannel',
      { name: trimmed }
    );
    emit('created', createdInbox.value);
  } catch (error) {
    const key = CREATE_ERRORS[error?.response?.data?.error] || 'GENERIC';
    const message = t(`INBOX_MGMT.ADD.EVOLUTION.ERRORS.${key}`);
    if (key === 'NAME_TAKEN') nameError.value = message;
    else useAlert(message);
  } finally {
    creating.value = false;
  }
};

const goToAgents = () => {
  const inboxId = createdInbox.value.id;
  dialogRef.value?.close();
  router.push({
    name: 'settings_inboxes_add_agents',
    params: { page: 'new', inbox_id: inboxId },
  });
};

const onClose = () => emit('closed', createdInbox.value);

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    overflow-y-auto
    :title="title"
    :description="
      createdInbox ? '' : $t('WHATSAPP_CONNECTIONS.NEW.DESCRIPTION')
    "
    :confirm-button-label="$t('INBOX_MGMT.ADD.EVOLUTION.SUBMIT')"
    :show-confirm-button="!createdInbox"
    :cancel-button-label="
      createdInbox
        ? $t('WHATSAPP_CONNECTIONS.NEW.DONE')
        : $t('WHATSAPP_CONNECTIONS.NEW.CANCEL')
    "
    :is-loading="creating"
    @confirm="create"
    @close="onClose"
  >
    <div v-if="!createdInbox" class="flex flex-col gap-2">
      <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
        {{ $t('INBOX_MGMT.ADD.EVOLUTION.NAME.LABEL') }}
        <input
          ref="nameInput"
          v-model="name"
          type="text"
          maxlength="100"
          class="!mb-0"
          :class="{ '!border-n-ruby-8': nameError }"
          :placeholder="$t('INBOX_MGMT.ADD.EVOLUTION.NAME.PLACEHOLDER')"
        />
      </label>
      <p v-if="nameError" class="text-xs text-n-ruby-11">{{ nameError }}</p>
      <p class="text-xs text-n-slate-11">
        {{ $t('INBOX_MGMT.ADD.EVOLUTION.NAME.HELP') }}
      </p>
    </div>

    <template v-else>
      <EvolutionConnection
        :inbox-id="createdInbox.id"
        auto-connect
        @connected="emit('connected', createdInbox)"
      />
      <div
        class="flex items-center justify-between gap-3 p-3 rounded-xl bg-n-alpha-1 text-xs text-n-slate-11"
      >
        <span>{{ $t('WHATSAPP_CONNECTIONS.NEW.AGENTS_HINT') }}</span>
        <NextButton
          type="button"
          size="sm"
          variant="faded"
          color="slate"
          icon="i-lucide-users"
          :label="$t('WHATSAPP_CONNECTIONS.NEW.ASSIGN_AGENTS')"
          @click="goToAgents"
        />
      </div>
    </template>
  </Dialog>
</template>
