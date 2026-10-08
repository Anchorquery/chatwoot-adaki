<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const { t } = useI18n();

const dialogRef = ref(null);
const inbox = ref(null);
const loading = ref(false);
const saving = ref(false);
// Sin los ajustes vigentes cargados no se deja guardar: se pisaría la
// configuración real de Evolution con todo apagado.
const loaded = ref(false);
const loadError = ref(false);
const form = ref({});

const TOGGLES = [
  'reject_call',
  'groups_ignore',
  'newsletter_ignore',
  'always_online',
  'read_messages',
  'read_status',
];

const toggles = computed(() =>
  TOGGLES.map(key => ({
    key,
    label: t(`WHATSAPP_CONNECTIONS.SETTINGS.FIELDS.${key.toUpperCase()}.LABEL`),
    help: t(`WHATSAPP_CONNECTIONS.SETTINGS.FIELDS.${key.toUpperCase()}.HELP`),
  }))
);

const load = async () => {
  loading.value = true;
  loaded.value = false;
  loadError.value = false;
  try {
    const { data } = await InboxesAPI.getEvolutionInstanceSettings(
      inbox.value.id
    );
    form.value = { msg_call: '', ...data.settings };
    TOGGLES.forEach(key => {
      form.value[key] = form.value[key] === true;
    });
    loaded.value = true;
  } catch {
    loadError.value = true;
  } finally {
    loading.value = false;
  }
};

const open = target => {
  inbox.value = target;
  form.value = {};
  dialogRef.value?.open();
  load();
};

const save = async () => {
  if (!loaded.value) return;
  saving.value = true;
  try {
    await InboxesAPI.updateEvolutionInstanceSettings(inbox.value.id, {
      ...form.value,
    });
    useAlert(t('WHATSAPP_CONNECTIONS.SETTINGS.SAVE_SUCCESS'));
    dialogRef.value?.close();
  } catch {
    useAlert(t('WHATSAPP_CONNECTIONS.SETTINGS.SAVE_ERROR'));
  } finally {
    saving.value = false;
  }
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="xl"
    overflow-y-auto
    :title="$t('WHATSAPP_CONNECTIONS.SETTINGS.TITLE', { name: inbox?.name })"
    :description="$t('WHATSAPP_CONNECTIONS.SETTINGS.DESCRIPTION')"
    :confirm-button-label="$t('WHATSAPP_CONNECTIONS.SETTINGS.SAVE')"
    :is-loading="saving"
    :disable-confirm-button="!loaded"
    @confirm="save"
  >
    <div v-if="loading" class="flex justify-center py-8">
      <Spinner class="size-5 text-n-slate-10" />
    </div>

    <div
      v-else-if="loadError"
      class="flex flex-col items-start gap-3 p-4 rounded-xl bg-n-ruby-2 text-sm text-n-ruby-11"
    >
      <p>{{ $t('WHATSAPP_CONNECTIONS.SETTINGS.LOAD_ERROR') }}</p>
      <NextButton
        type="button"
        size="sm"
        variant="faded"
        color="ruby"
        icon="i-lucide-refresh-cw"
        :label="$t('WHATSAPP_CONNECTIONS.SETTINGS.RETRY')"
        @click="load"
      />
    </div>

    <ul v-else class="flex flex-col divide-y divide-n-weak">
      <li
        v-for="toggle in toggles"
        :key="toggle.key"
        class="flex flex-col gap-3 py-3 first:pt-0"
      >
        <label class="flex items-start justify-between gap-4 cursor-pointer">
          <span class="flex flex-col gap-0.5">
            <span class="text-sm font-medium text-n-slate-12">
              {{ toggle.label }}
            </span>
            <span class="text-xs text-n-slate-11">{{ toggle.help }}</span>
          </span>
          <Switch v-model="form[toggle.key]" class="mt-1" />
        </label>
        <textarea
          v-if="toggle.key === 'reject_call' && form.reject_call"
          v-model="form.msg_call"
          rows="2"
          maxlength="500"
          class="!mb-0 text-sm"
          :placeholder="
            $t('WHATSAPP_CONNECTIONS.SETTINGS.MSG_CALL_PLACEHOLDER')
          "
        />
      </li>
    </ul>
  </Dialog>
</template>
