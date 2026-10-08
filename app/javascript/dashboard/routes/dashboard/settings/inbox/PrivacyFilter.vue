<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import PrivacyModeSelector from './privacy/PrivacyModeSelector.vue';
import PrivacySearchPanel from './privacy/PrivacySearchPanel.vue';
import PrivacySelectedList from './privacy/PrivacySelectedList.vue';
import {
  normalizeJid,
  jidType,
  phoneFromJid,
  sameSelection,
} from './privacy/privacyHelpers';

// Página propia del filtro de chats: la usan administradores y también los
// agentes asignados a la bandeja, sin abrir toda su configuración.
const { t } = useI18n();
const route = useRoute();
const store = useStore();

const inboxId = computed(() => route.params.inboxId);
const getInbox = useMapGetter('inboxes/getInbox');
const inbox = computed(() => getInbox.value(inboxId.value) || {});

const loading = ref(true);
// Sin el filtro vigente cargado no se deja guardar: se pisaría la config real
// de Evolution con el estado por defecto.
const loaded = ref(false);
const saving = ref(false);
const conflict = ref(false);

const mode = ref('all');
const selected = ref([]);
const original = ref({ mode: 'all', jids: [] });
// Último modo con lista (bloquear o "solo estos"); ver el watch de mode.
let lastListMode = null;

const selectedJids = computed(
  () => new Set(selected.value.map(item => item.jid))
);

const isDirty = computed(
  () =>
    loaded.value &&
    !sameSelection(original.value, {
      mode: mode.value,
      jids: [...selectedJids.value],
    })
);

// Un filtro "bloquear" o "solo estos" con la lista vacía equivale a recibir
// todo: se pide al menos un chat para no guardar algo engañoso.
const missingSelection = computed(
  () => mode.value !== 'all' && selected.value.length === 0
);

const itemFor = (jid, label = {}) => ({
  jid,
  type: jidType(jid),
  name: label.name || (label.phone ? `+${label.phone}` : null),
  phone: label.phone || phoneFromJid(jid),
});

const resolveNames = async jids => {
  if (!jids.length) return;
  try {
    const { data } = await InboxesAPI.resolveEvolutionPrivacy(
      inboxId.value,
      jids
    );
    const labels = data.labels || {};
    selected.value = selected.value.map(item =>
      labels[item.jid]?.name ? { ...item, name: labels[item.jid].name } : item
    );
  } catch {
    // Sin nombres la lista sigue siendo correcta: se ven los números.
  }
};

const load = async () => {
  loading.value = true;
  loaded.value = false;
  try {
    const { data } = await InboxesAPI.getEvolutionPrivacyFilter(inboxId.value);
    const jids = [
      ...(data.contact_jids || []),
      ...(data.group_jids || []),
      ...(data.channel_jids || []),
    ].map(normalizeJid);
    const unique = [...new Set(jids)];

    mode.value = data.mode || 'all';
    conflict.value = Boolean(data.conflict);
    selected.value = unique.map(jid => itemFor(jid));
    original.value = { mode: mode.value, jids: unique };
    lastListMode = mode.value === 'all' ? null : mode.value;
    loaded.value = true;
    resolveNames(unique);
  } catch {
    loaded.value = false;
  } finally {
    loading.value = false;
  }
};

// Bloquear y "solo estos" usan la lista al revés: llevar la de un modo al otro
// convertiría a los bloqueados en los únicos que llegan. Al cambiar entre
// ellos la lista empieza vacía ("Descartar" la recupera).
watch(mode, newMode => {
  if (newMode === 'all') return;
  if (lastListMode && newMode !== lastListMode) selected.value = [];
  lastListMode = newMode;
});

const add = item => {
  if (selectedJids.value.has(item.jid)) return;
  selected.value = [{ ...item }, ...selected.value];
};

const remove = item => {
  selected.value = selected.value.filter(entry => entry.jid !== item.jid);
};

const clearAll = () => {
  selected.value = [];
};

const discard = () => {
  const jids = original.value.jids;
  lastListMode = original.value.mode === 'all' ? null : original.value.mode;
  mode.value = original.value.mode;
  const byJid = new Map(selected.value.map(item => [item.jid, item]));
  selected.value = jids.map(jid => byJid.get(jid) || itemFor(jid));
  resolveNames(jids.filter(jid => !byJid.has(jid)));
};

const SAVE_ERROR_REASONS = ['not_configured', 'invalid_mode'];

const save = async () => {
  if (!loaded.value || missingSelection.value) return;
  saving.value = true;
  const jids = mode.value === 'all' ? [] : [...selectedJids.value];
  // Los nombres viajan con el guardado: los chats excluidos nunca llegan a
  // Chatwoot, y sin esto se volverían a ver como números al recargar.
  const labels = Object.fromEntries(
    selected.value
      .filter(item => item.name && item.name !== `+${item.phone}`)
      .map(item => [item.jid, item.name])
  );
  try {
    await InboxesAPI.updateEvolutionPrivacyFilter(inboxId.value, {
      mode: mode.value,
      jids,
      labels,
    });
    original.value = { mode: mode.value, jids };
    conflict.value = false;
    useAlert(t('PRIVACY_FILTER.SAVE_SUCCESS'));
  } catch (error) {
    const reason = error?.response?.data?.message;
    useAlert(
      SAVE_ERROR_REASONS.includes(reason)
        ? t(
            `INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.SAVE_ERROR_${reason.toUpperCase()}`
          )
        : t('PRIVACY_FILTER.SAVE_ERROR')
    );
  } finally {
    saving.value = false;
  }
};

onMounted(() => {
  if (!inbox.value.id) store.dispatch('inboxes/get');
  load();
});
</script>

<template>
  <div class="flex flex-col w-full max-w-6xl gap-6 px-1 pb-8 mx-auto">
    <!-- Las acciones van en la cabecera y no en una barra fija abajo: fijada al
         fondo de la zona de scroll flotaba a media pantalla y tapaba la lista. -->
    <header class="flex flex-wrap items-start justify-between gap-4">
      <div class="flex flex-col gap-1 min-w-0 flex-1">
        <h1 class="text-heading-1 text-n-slate-12">
          {{ $t('PRIVACY_FILTER.TITLE') }}
        </h1>
        <p class="text-body-main text-n-slate-11 max-w-3xl">
          {{
            $t('PRIVACY_FILTER.DESCRIPTION', {
              name: inbox.name || '',
            })
          }}
        </p>
      </div>
      <div v-if="loaded" class="flex flex-col items-end gap-1.5 shrink-0">
        <div class="flex items-center gap-2">
          <NextButton
            v-if="isDirty"
            type="button"
            size="sm"
            variant="ghost"
            color="slate"
            :label="$t('PRIVACY_FILTER.DISCARD')"
            @click="discard"
          />
          <NextButton
            type="button"
            size="sm"
            icon="i-lucide-save"
            :label="$t('PRIVACY_FILTER.SAVE')"
            :is-loading="saving"
            :disabled="!isDirty || missingSelection"
            @click="save"
          />
        </div>
        <span
          class="text-xs text-end max-w-xs"
          :class="
            missingSelection
              ? 'text-n-amber-11'
              : isDirty
                ? 'text-n-blue-11'
                : 'text-n-slate-11'
          "
        >
          {{
            missingSelection
              ? $t('PRIVACY_FILTER.MISSING_SELECTION')
              : isDirty
                ? $t('PRIVACY_FILTER.UNSAVED')
                : $t('PRIVACY_FILTER.SAVED')
          }}
        </span>
      </div>
    </header>

    <div v-if="loading" class="flex items-center gap-2 py-10 text-n-slate-11">
      <Spinner class="size-4" />
      <span class="text-sm">{{ $t('PRIVACY_FILTER.LOADING') }}</span>
    </div>

    <div
      v-else-if="!loaded"
      class="flex flex-col items-start gap-3 p-4 rounded-xl bg-n-ruby-2"
    >
      <p class="text-sm text-n-ruby-11">
        {{ $t('PRIVACY_FILTER.LOAD_ERROR') }}
      </p>
      <NextButton
        type="button"
        size="sm"
        variant="faded"
        color="ruby"
        icon="i-lucide-refresh-cw"
        :label="$t('PRIVACY_FILTER.RETRY')"
        @click="load"
      />
    </div>

    <template v-else>
      <p
        v-if="conflict"
        class="flex items-start gap-2 p-3 text-sm rounded-xl bg-n-amber-2 text-n-amber-11"
      >
        <span class="i-lucide-triangle-alert size-4 shrink-0 mt-0.5" />
        {{ $t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.CONFLICT_WARNING') }}
      </p>

      <PrivacyModeSelector v-model="mode" />

      <div
        v-if="mode !== 'all'"
        class="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start"
      >
        <PrivacySearchPanel
          :inbox-id="inboxId"
          :mode="mode"
          :selected-jids="selectedJids"
          @add="add"
        />
        <PrivacySelectedList
          :items="selected"
          :mode="mode"
          @remove="remove"
          @clear="clearAll"
        />
      </div>

      <p
        v-else
        class="flex items-start gap-2 p-4 text-sm rounded-xl border border-n-weak text-n-slate-11"
      >
        <span class="i-lucide-info size-4 shrink-0 mt-0.5" />
        {{ $t('PRIVACY_FILTER.ALL_HINT') }}
      </p>
    </template>
  </div>
</template>
