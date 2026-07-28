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
// Sin el filtro actual cargado, guardar pisaría la config existente con el
// estado por defecto ("Todos" vacío). Se deshabilita el guardado hasta releer.
const filterLoaded = ref(false);
// El listado de audiencias (nombres reales) es admin-only a propósito: expone
// TODOS los chats del número, incluidos los que este mismo filtro oculta. Un
// agente recibe 403 ahí y cae a texto libre, pero el filtro sí puede leerlo.
const optionsLoaded = ref(false);

const modeItems = computed(() =>
  MODES.map(value => ({
    id: value,
    title: t(
      `INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.MODES.${value.toUpperCase()}`
    ),
    checked: mode.value === value,
  }))
);

// Con nombres reales solo si la conexión ya se probó Y el listado de
// audiencias respondió (a un agente le da 403); si no, texto libre (mismo
// criterio que el picker de audiencias de Captain).
const hasNamedOptions = computed(() => props.connected && optionsLoaded.value);

const loadOptionsAndFilter = async () => {
  loading.value = true;
  try {
    // allSettled, no all: audiencias es admin-only y para un agente rechaza
    // con 403. Con Promise.all ese rechazo descartaba también el filtro (que
    // el agente sí puede leer) y el agente veía "Todos" vacío — y al guardar,
    // pisaba el filtro configurado.
    const [optionsResult, filterResult] = await Promise.allSettled([
      InboxesAPI.getEvolutionAudienceOptions(props.inboxId),
      InboxesAPI.getEvolutionPrivacyFilter(props.inboxId),
    ]);

    optionsLoaded.value = optionsResult.status === 'fulfilled';
    if (optionsLoaded.value) {
      const options = optionsResult.value.data;
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
    }

    if (filterResult.status === 'rejected') {
      throw filterResult.reason;
    }
    const filter = filterResult.value.data;
    mode.value = filter.mode || 'all';
    groupJids.value = filter.group_jids || [];
    channelJids.value = filter.channel_jids || [];
    contactJids.value = filter.contact_jids || [];
    filterLoaded.value = true;
  } catch (error) {
    // El GET del filtro devuelve 200 con defaults cuando la conexión no está
    // configurada; llegar acá es un error real (permisos, Evolution caído).
    // Se deja el guardado deshabilitado para no pisar la config guardada.
    filterLoaded.value = false;
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
    <p
      v-if="!loading && !filterLoaded"
      class="text-xs text-n-ruby-11 flex items-start gap-1.5"
    >
      <span class="i-lucide-triangle-alert size-3.5 shrink-0 mt-0.5" />
      {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.LOAD_ERROR') }}
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
      :disabled="loading || !filterLoaded"
      @click="save"
    />
  </div>
</template>
