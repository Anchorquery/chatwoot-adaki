<script setup>
import { computed, ref, watch } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRoute } from 'vue-router';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Policy from 'dashboard/components/policy.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import { INBOX_TYPES, getInboxIconByType } from 'dashboard/helper/inbox';
import InboxesAPI from 'dashboard/api/inboxes';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  inbox: {
    type: Object,
    required: true,
  },
  audiences: {
    type: Array,
    default: () => [],
  },
});

const emit = defineEmits(['action']);

const { t } = useI18n();

const [showActionsDropdown, toggleDropdown] = useToggle();

const inboxName = computed(() => {
  const inbox = props.inbox;
  if (!inbox?.name) {
    return '';
  }

  const isTwilioChannel = inbox.channel_type === INBOX_TYPES.TWILIO;
  const isWhatsAppChannel = inbox.channel_type === INBOX_TYPES.WHATSAPP;
  const isEmailChannel = inbox.channel_type === INBOX_TYPES.EMAIL;

  if (isTwilioChannel || isWhatsAppChannel) {
    const identifier = inbox.messaging_service_sid || inbox.phone_number;
    return identifier ? `${inbox.name} (${identifier})` : inbox.name;
  }

  if (isEmailChannel && inbox.email) {
    return `${inbox.name} (${inbox.email})`;
  }

  return inbox.name;
});

const menuItems = computed(() => [
  {
    label: t('CAPTAIN.INBOXES.OPTIONS.DISCONNECT'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  },
]);

const icon = computed(() => {
  const { medium, channel_type: type } = props.inbox;
  return getInboxIconByType(type, medium, 'outline');
});

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};

const store = useStore();
const route = useRoute();
const assistantId = computed(() => Number(route.params.assistantId));

const ci = computed(() => props.inbox.captain_inbox || {});
const effective = computed(() => ci.value.effective || {});
const settings = computed(() => ci.value.settings || {});

const showOverrides = ref(false);

const localContinue = ref(null);
const localAutoHandoff = ref(null);
const localHours = ref(null);
const localTakeoverMode = ref(null);
const localTakeoverWindow = ref(null);
// null = inherit from the assistant, 0 = explicitly no team, N = team id
const localHandoffTeam = ref(null);

const HUMAN_TAKEOVER_MODES = ['always', 'after_window', 'never'];

const teams = useMapGetter('teams/getTeams');
const teamName = teamId => {
  const team = teams.value.find(item => item.id === Number(teamId));
  return team ? team.name : t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.NONE');
};

const syncLocal = () => {
  localContinue.value =
    settings.value.continue_after_human_takeover === undefined
      ? null
      : !!settings.value.continue_after_human_takeover;
  localAutoHandoff.value =
    settings.value.auto_handoff_enabled === undefined
      ? null
      : !!settings.value.auto_handoff_enabled;
  localHours.value =
    settings.value.auto_resolve_hours === undefined
      ? null
      : Number(settings.value.auto_resolve_hours);
  localTakeoverMode.value = HUMAN_TAKEOVER_MODES.includes(
    settings.value.human_takeover_mode
  )
    ? settings.value.human_takeover_mode
    : null;
  localTakeoverWindow.value =
    settings.value.human_takeover_window_minutes === undefined
      ? null
      : Number(settings.value.human_takeover_window_minutes);
  localHandoffTeam.value =
    settings.value.handoff_team_id === undefined ||
    settings.value.handoff_team_id === null
      ? null
      : Number(settings.value.handoff_team_id);
};
watch(() => props.inbox, syncLocal, { immediate: true, deep: true });

const saving = ref(false);
const saveOverride = async patch => {
  saving.value = true;
  try {
    const newSettings = { ...settings.value, ...patch };
    await store.dispatch('captainInboxes/updateSettings', {
      assistantId: assistantId.value,
      inboxId: props.id,
      settings: newSettings,
    });
  } finally {
    saving.value = false;
  }
};

const clearOverride = async key => {
  const newSettings = { ...settings.value };
  delete newSettings[key];
  saving.value = true;
  try {
    await store.dispatch('captainInboxes/updateSettings', {
      assistantId: assistantId.value,
      inboxId: props.id,
      settings: newSettings,
    });
  } finally {
    saving.value = false;
  }
};

// Audiences: per-inbox Captain assignment by WhatsApp group JID and/or
// conversation label, resolved by Conversation#resolved_captain_assistant.
// A conversation that doesn't match any audience here falls back to this
// inbox's default assistant above (or to no assistant, if none is set).
const labelRecords = useMapGetter('labels/getLabels');
const labelOptions = computed(() =>
  labelRecords.value.map(label => ({ value: label.title, label: label.title }))
);

const newGroupJids = ref([]);
const newChannelJids = ref([]);
const newLabelTitles = ref([]);
const addingAudience = ref(false);
const canAddAudience = computed(
  () =>
    newGroupJids.value.length > 0 ||
    newChannelJids.value.length > 0 ||
    newLabelTitles.value.length > 0
);

// Grupos/canales de WhatsApp con nombre real, traídos de Evolution API
// (ver Evolution::AudienceOptionsService) en vez de que el admin tipee el JID.
// Solo se pide si la conexión ya se probó con éxito (Settings > Bandejas >
// Configuración > "Probar conexión") — evita pegarle a Evolution a ciegas
// con una apikey no verificada.
const groupOptions = ref([]);
const channelOptions = ref([]);
const loadingAudienceOptions = ref(false);
const audienceOptionsLoaded = ref(false);
const evolutionVerified = computed(
  () => props.inbox.additional_attributes?.evolution_verified === true
);

const fetchAudienceOptions = async () => {
  if (!evolutionVerified.value) return;
  if (audienceOptionsLoaded.value || loadingAudienceOptions.value) return;
  loadingAudienceOptions.value = true;
  try {
    const { data } = await InboxesAPI.getEvolutionAudienceOptions(props.id);
    groupOptions.value = (data.groups || []).map(group => ({
      value: group.id,
      label: group.subject || group.id,
    }));
    channelOptions.value = (data.newsletters || []).map(newsletter => ({
      value: newsletter.id,
      label: newsletter.name || newsletter.id,
    }));
    audienceOptionsLoaded.value = true;
  } catch (error) {
    // Se cae a los campos de texto manual; el aviso de arriba ya explica al
    // usuario que tiene que configurar y probar la conexión a Evolution.
    // eslint-disable-next-line no-console
    console.warn('Could not fetch Evolution audience options', error);
  } finally {
    loadingAudienceOptions.value = false;
  }
};

watch(showOverrides, isOpen => {
  if (isOpen) fetchAudienceOptions();
});

// La conexión a Evolution (URL, apikey, instancia) se configura en
// Settings > Bandejas > (canal API) > Configuración, no acá — es
// config del canal, no del asistente. Ver Evolution::AudienceOptionsService.
const jidLabelMap = computed(() => {
  const map = {};
  [...groupOptions.value, ...channelOptions.value].forEach(option => {
    map[option.value] = option.label;
  });
  return map;
});
const labelForJid = jid => jidLabelMap.value[jid] || jid;

const addAudience = async () => {
  if (!canAddAudience.value) return;
  addingAudience.value = true;
  try {
    await store.dispatch('captainInboxAudiences/create', {
      assistantId: assistantId.value,
      inboxId: props.id,
      groupJids: newGroupJids.value,
      channelJids: newChannelJids.value,
      labelTitles: newLabelTitles.value,
    });
    newGroupJids.value = [];
    newChannelJids.value = [];
    newLabelTitles.value = [];
  } finally {
    addingAudience.value = false;
  }
};

const removeAudience = audienceId => {
  store.dispatch('captainInboxAudiences/delete', {
    assistantId: assistantId.value,
    id: audienceId,
  });
};
</script>

<template>
  <CardLayout>
    <div class="flex justify-between w-full gap-1">
      <span
        class="text-base text-n-slate-12 line-clamp-1 flex items-center gap-2"
      >
        <span :class="icon" />
        {{ inboxName }}
      </span>
      <div class="flex items-center gap-2">
        <Button
          :icon="
            showOverrides
              ? 'i-lucide-chevron-up'
              : 'i-lucide-sliders-horizontal'
          "
          color="slate"
          size="xs"
          class="rounded-md"
          @click="showOverrides = !showOverrides"
        />
        <Policy
          v-on-clickaway="() => toggleDropdown(false)"
          :permissions="['administrator']"
          class="relative flex items-center group"
        >
          <Button
            icon="i-lucide-ellipsis-vertical"
            color="slate"
            size="xs"
            class="rounded-md group-hover:bg-n-alpha-2"
            @click="toggleDropdown()"
          />
          <DropdownMenu
            v-if="showActionsDropdown"
            :menu-items="menuItems"
            class="mt-1 ltr:right-0 rtl:left-0 top-full"
            @action="handleAction($event)"
          />
        </Policy>
      </div>
    </div>

    <div
      v-if="showOverrides"
      class="mt-4 pt-4 border-t border-n-weak flex flex-col gap-4"
    >
      <p class="text-xs text-n-slate-11">
        {{ t('CAPTAIN.INBOXES.OVERRIDES.HINT') }}
      </p>

      <!-- continue_after_human_takeover -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.CONTINUE_AFTER_TAKEOVER.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: effective.continue_after_human_takeover
                  ? t('CAPTAIN.INBOXES.OVERRIDES.ON')
                  : t('CAPTAIN.INBOXES.OVERRIDES.OFF'),
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <select
            :value="localContinue === null ? 'inherit' : String(localContinue)"
            :disabled="saving"
            class="text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              $event.target.value === 'inherit'
                ? clearOverride('continue_after_human_takeover')
                : saveOverride({
                    continue_after_human_takeover:
                      $event.target.value === 'true',
                  })
            "
          >
            <option value="inherit">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.INHERIT') }}
            </option>
            <option value="true">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.ON') }}
            </option>
            <option value="false">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.OFF') }}
            </option>
          </select>
        </div>
      </div>

      <!-- auto_handoff_enabled -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_HANDOFF.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: effective.auto_handoff_enabled
                  ? t('CAPTAIN.INBOXES.OVERRIDES.ON')
                  : t('CAPTAIN.INBOXES.OVERRIDES.OFF'),
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <select
            :value="
              localAutoHandoff === null ? 'inherit' : String(localAutoHandoff)
            "
            :disabled="saving"
            class="text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              $event.target.value === 'inherit'
                ? clearOverride('auto_handoff_enabled')
                : saveOverride({
                    auto_handoff_enabled: $event.target.value === 'true',
                  })
            "
          >
            <option value="inherit">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.INHERIT') }}
            </option>
            <option value="true">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.ON') }}
            </option>
            <option value="false">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.OFF') }}
            </option>
          </select>
        </div>
      </div>

      <!-- human_takeover_mode -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: effective.human_takeover_mode || 'after_window',
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <select
            :value="localTakeoverMode === null ? 'inherit' : localTakeoverMode"
            :disabled="saving"
            class="text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              $event.target.value === 'inherit'
                ? clearOverride('human_takeover_mode')
                : saveOverride({ human_takeover_mode: $event.target.value })
            "
          >
            <option value="inherit">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.INHERIT') }}
            </option>
            <option value="always">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.ALWAYS')
              }}
            </option>
            <option value="after_window">
              {{
                t(
                  'CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.AFTER_WINDOW'
                )
              }}
            </option>
            <option value="never">
              {{
                t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_MODE.OPTIONS.NEVER')
              }}
            </option>
          </select>
        </div>
      </div>

      <!-- human_takeover_window_minutes -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.HUMAN_TAKEOVER_WINDOW.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: (effective.human_takeover_window_minutes || 15) + 'm',
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <input
            v-model.number="localTakeoverWindow"
            type="number"
            min="1"
            max="10080"
            :placeholder="t('CAPTAIN.INBOXES.OVERRIDES.INHERIT')"
            :disabled="saving"
            class="w-24 text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              localTakeoverWindow
                ? saveOverride({
                    human_takeover_window_minutes: Number(localTakeoverWindow),
                  })
                : clearOverride('human_takeover_window_minutes')
            "
          />
        </div>
      </div>

      <!-- handoff_team_id -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: teamName(effective.handoff_team_id),
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <select
            :value="
              localHandoffTeam === null ? 'inherit' : String(localHandoffTeam)
            "
            :disabled="saving"
            class="text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              $event.target.value === 'inherit'
                ? clearOverride('handoff_team_id')
                : saveOverride({
                    handoff_team_id: Number($event.target.value),
                  })
            "
          >
            <option value="inherit">
              {{ t('CAPTAIN.INBOXES.OVERRIDES.INHERIT') }}
            </option>
            <option value="0">
              {{ t('CAPTAIN.ASSISTANTS.FORM.HANDOFF_TEAM.NONE') }}
            </option>
            <option
              v-for="team in teams"
              :key="team.id"
              :value="String(team.id)"
            >
              {{ team.name }}
            </option>
          </select>
        </div>
      </div>

      <!-- auto_resolve_hours -->
      <div class="flex items-start justify-between gap-3">
        <div class="flex-1">
          <p class="text-sm font-medium text-n-slate-12">
            {{ t('CAPTAIN.ASSISTANTS.FORM.AUTO_RESOLVE_HOURS.LABEL') }}
          </p>
          <p class="text-xs text-n-slate-11">
            {{
              t('CAPTAIN.INBOXES.OVERRIDES.EFFECTIVE', {
                value: effective.auto_resolve_hours + 'h',
              })
            }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <input
            v-model.number="localHours"
            type="number"
            min="1"
            max="720"
            :placeholder="t('CAPTAIN.INBOXES.OVERRIDES.INHERIT')"
            :disabled="saving"
            class="w-24 text-xs rounded-md border border-n-weak bg-n-alpha-black2 px-2 py-1 text-n-slate-12"
            @change="
              localHours
                ? saveOverride({ auto_resolve_hours: Number(localHours) })
                : clearOverride('auto_resolve_hours')
            "
          />
        </div>
      </div>

      <!-- audiences -->
      <div class="pt-4 border-t border-n-weak flex flex-col gap-3">
        <p class="text-xs text-n-slate-11">
          {{ t('CAPTAIN.INBOXES.AUDIENCES.HINT') }}
        </p>
        <p
          v-if="!evolutionVerified"
          class="text-xs text-n-amber-11 flex items-start gap-1.5"
        >
          <span class="i-lucide-info size-3.5 shrink-0 mt-0.5" />
          {{ t('CAPTAIN.INBOXES.AUDIENCES.NO_EVOLUTION_OPTIONS') }}
        </p>

        <div
          v-for="audience in audiences"
          :key="audience.id"
          class="flex items-start justify-between gap-3 rounded-md border border-n-weak p-2"
        >
          <div class="flex-1 flex flex-wrap gap-1.5 text-xs text-n-slate-12">
            <span
              v-for="jid in audience.group_jids"
              :key="`jid-${jid}`"
              class="flex items-center gap-1 rounded bg-n-alpha-2 px-1.5 py-0.5"
            >
              <span class="i-lucide-users size-3 text-n-slate-11" />
              {{ labelForJid(jid) }}
            </span>
            <span
              v-for="jid in audience.channel_jids"
              :key="`channel-jid-${jid}`"
              class="flex items-center gap-1 rounded bg-n-alpha-2 px-1.5 py-0.5"
            >
              <span class="i-lucide-radio size-3 text-n-slate-11" />
              {{ labelForJid(jid) }}
            </span>
            <span
              v-for="title in audience.label_titles"
              :key="`label-${title}`"
              class="flex items-center gap-1 rounded bg-n-alpha-2 px-1.5 py-0.5"
            >
              <span class="i-lucide-tag size-3 text-n-slate-11" />
              {{ title }}
            </span>
          </div>
          <Button
            icon="i-lucide-trash"
            color="slate"
            size="xs"
            class="rounded-md"
            @click="removeAudience(audience.id)"
          />
        </div>

        <div class="flex flex-col gap-3">
          <div class="flex flex-col gap-1">
            <label
              class="flex items-center gap-1.5 text-xs font-medium text-n-slate-11"
            >
              <span class="i-lucide-users size-3.5" />
              {{ t('CAPTAIN.INBOXES.AUDIENCES.GROUP_JIDS_LABEL') }}
            </label>
            <TagMultiSelectComboBox
              v-if="groupOptions.length"
              v-model="newGroupJids"
              :options="groupOptions"
              :placeholder="
                t('CAPTAIN.INBOXES.AUDIENCES.GROUP_JIDS_PLACEHOLDER')
              "
            />
            <TagInput
              v-else
              v-model="newGroupJids"
              type="text"
              allow-create
              :show-dropdown="false"
              :placeholder="
                t('CAPTAIN.INBOXES.AUDIENCES.GROUP_JIDS_MANUAL_PLACEHOLDER')
              "
            />
          </div>
          <div class="flex flex-col gap-1">
            <label
              class="flex items-center gap-1.5 text-xs font-medium text-n-slate-11"
            >
              <span class="i-lucide-radio size-3.5" />
              {{ t('CAPTAIN.INBOXES.AUDIENCES.CHANNEL_JIDS_LABEL') }}
            </label>
            <TagMultiSelectComboBox
              v-if="channelOptions.length"
              v-model="newChannelJids"
              :options="channelOptions"
              :placeholder="
                t('CAPTAIN.INBOXES.AUDIENCES.CHANNEL_JIDS_PLACEHOLDER')
              "
            />
            <TagInput
              v-else
              v-model="newChannelJids"
              type="text"
              allow-create
              :show-dropdown="false"
              :placeholder="
                t('CAPTAIN.INBOXES.AUDIENCES.CHANNEL_JIDS_MANUAL_PLACEHOLDER')
              "
            />
          </div>
          <div class="flex flex-col gap-1">
            <label
              class="flex items-center gap-1.5 text-xs font-medium text-n-slate-11"
            >
              <span class="i-lucide-tag size-3.5" />
              {{ t('CAPTAIN.INBOXES.AUDIENCES.LABELS_LABEL') }}
            </label>
            <TagMultiSelectComboBox
              v-model="newLabelTitles"
              :options="labelOptions"
              :placeholder="t('CAPTAIN.INBOXES.AUDIENCES.LABELS_PLACEHOLDER')"
            />
          </div>
          <Button
            :label="t('CAPTAIN.INBOXES.AUDIENCES.ADD')"
            size="xs"
            class="rounded-md self-start"
            :disabled="!canAddAudience || addingAudience"
            :is-loading="addingAudience"
            @click="addAudience"
          />
        </div>
      </div>
    </div>
  </CardLayout>
</template>
