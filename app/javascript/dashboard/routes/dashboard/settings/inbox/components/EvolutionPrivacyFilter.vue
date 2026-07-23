<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import InputRadioGroup from './InputRadioGroup.vue';

const props = defineProps({
  inboxId: {
    type: [String, Number],
    required: true,
  },
  connected: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();

const MODES = ['all', 'block', 'allow'];
const mode = ref('all');
const groupJids = ref([]);
const channelJids = ref([]);
const contactJids = ref([]);

const groupOptions = ref([]);
const channelOptions = ref([]);
const contactOptions = ref([]);

const loading = ref(false);
const saving = ref(false);

const modeItems = computed(() =>
  MODES.map(value => ({
    id: value,
    title: t(
      `INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.MODES.${value.toUpperCase()}`
    ),
    checked: mode.value === value,
  }))
);

// Con nombres reales solo si la conexión ya se probó; si no, se cae a texto
// libre (mismo criterio que el picker de audiencias de Captain).
const hasNamedOptions = computed(() => props.connected);

const loadOptionsAndFilter = async () => {
  loading.value = true;
  try {
    const [{ data: options }, { data: filter }] = await Promise.all([
      InboxesAPI.getEvolutionAudienceOptions(props.inboxId),
      InboxesAPI.getEvolutionPrivacyFilter(props.inboxId),
    ]);

    groupOptions.value = (options.groups || []).map(group => ({
      value: group.id,
      label: group.subject || group.id,
    }));
    channelOptions.value = (options.newsletters || []).map(newsletter => ({
      value: newsletter.id,
      label: newsletter.name || newsletter.id,
    }));
    contactOptions.value = (options.contacts || []).map(contact => ({
      value: contact.remoteJid,
      label: contact.pushName || contact.remoteJid?.split('@')[0],
    }));

    mode.value = filter.mode || 'all';
    groupJids.value = filter.group_jids || [];
    channelJids.value = filter.channel_jids || [];
    contactJids.value = filter.contact_jids || [];
  } catch (error) {
    // Sin conexión configurada/verificada todavía; queda en modo "Todos"
    // con listas vacías, el usuario puede seguir usando texto libre.
    // eslint-disable-next-line no-console
    console.warn('Could not load Evolution privacy filter', error);
  } finally {
    loading.value = false;
  }
};

onMounted(loadOptionsAndFilter);
watch(() => props.connected, loadOptionsAndFilter);

const setMode = item => {
  mode.value = item.id;
};

const save = async () => {
  saving.value = true;
  try {
    const jids =
      mode.value === 'all'
        ? []
        : groupJids.value.concat(channelJids.value, contactJids.value);

    await InboxesAPI.updateEvolutionPrivacyFilter(props.inboxId, {
      mode: mode.value,
      jids,
    });
    useAlert(t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.SAVE_SUCCESS'));
  } catch {
    useAlert(t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.SAVE_ERROR'));
  } finally {
    saving.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <p class="text-xs text-n-slate-11">
      {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.HINT') }}
    </p>
    <p
      v-if="!hasNamedOptions"
      class="text-xs text-n-amber-11 flex items-start gap-1.5"
    >
      <span class="i-lucide-info size-3.5 shrink-0 mt-0.5" />
      {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.NO_CONNECTION_HINT') }}
    </p>

    <InputRadioGroup
      name="evolution-privacy-mode"
      :items="modeItems"
      :action="setMode"
    />

    <template v-if="mode !== 'all'">
      <div class="flex flex-col gap-1">
        <label class="text-xs font-medium text-n-slate-11">
          {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.GROUPS_LABEL') }}
        </label>
        <TagMultiSelectComboBox
          v-if="hasNamedOptions"
          v-model="groupJids"
          :options="groupOptions"
        />
        <TagInput
          v-else
          v-model="groupJids"
          type="text"
          allow-create
          :show-dropdown="false"
        />
      </div>
      <div class="flex flex-col gap-1">
        <label class="text-xs font-medium text-n-slate-11">
          {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.CHANNELS_LABEL') }}
        </label>
        <TagMultiSelectComboBox
          v-if="hasNamedOptions"
          v-model="channelJids"
          :options="channelOptions"
        />
        <TagInput
          v-else
          v-model="channelJids"
          type="text"
          allow-create
          :show-dropdown="false"
        />
      </div>
      <div class="flex flex-col gap-1">
        <label class="text-xs font-medium text-n-slate-11">
          {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.CONTACTS_LABEL') }}
        </label>
        <TagMultiSelectComboBox
          v-if="hasNamedOptions"
          v-model="contactJids"
          :options="contactOptions"
        />
        <TagInput
          v-else
          v-model="contactJids"
          type="text"
          allow-create
          :show-dropdown="false"
        />
      </div>
    </template>

    <NextButton
      :label="t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.SAVE_BUTTON')"
      size="sm"
      class="rounded-md self-start"
      :is-loading="saving"
      :disabled="loading"
      @click="save"
    />
  </div>
</template>
