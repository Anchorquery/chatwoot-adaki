<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';

import CampaignsAPI from 'dashboard/api/campaigns';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

// Buscador de grupos, grupos de avisos de comunidades y canales de la cuenta
// de WhatsApp de la bandeja, como el del filtro de privacidad: se escribe, el
// servidor busca y pagina. Lo elegido queda arriba con su nombre aunque ya no
// salga en la búsqueda.
//
// En los grupos de "solo admins" se comprueba, solo para los elegidos, si el
// número de la bandeja puede publicar.
const props = defineProps({
  inboxId: { type: [Number, String], default: null },
});

const chats = defineModel('chats', { type: Array, default: () => [] });
const chatNames = defineModel('chatNames', {
  type: Object,
  default: () => ({}),
});

const { t } = useI18n();
const tr = (key, params) =>
  t(`CAMPAIGN.API.CREATE.FORM.AUDIENCE.${key}`, params);

const KIND_FILTERS = [
  { value: '', label: 'CHATS_FILTER_ALL' },
  { value: 'group', label: 'CHATS_FILTER_GROUP' },
  { value: 'community', label: 'CHATS_FILTER_COMMUNITY' },
  { value: 'channel', label: 'CHATS_FILTER_CHANNEL' },
];
const KIND_ICONS = {
  group: 'i-lucide-users',
  community: 'i-lucide-megaphone',
  channel: 'i-lucide-radio',
};
const KIND_LABELS = {
  group: 'KIND_GROUP',
  community: 'KIND_COMMUNITY',
  channel: 'KIND_CHANNEL',
};

const kindOf = jid => (jid.endsWith('@newsletter') ? 'channel' : 'group');

// --- Búsqueda ---------------------------------------------------------------
const query = ref('');
const kind = ref('');
const items = ref([]);
const page = ref(1);
const hasMore = ref(false);
const loading = ref(false);
const loadingMore = ref(false);
const failed = ref(false);
const groupsUnavailable = ref(false);
// Filas vistas en alguna búsqueda, por JID: nombre y tipo de los elegidos.
const knownRows = ref({});
let requestSeq = 0;

const remember = rows => {
  knownRows.value = {
    ...knownRows.value,
    ...Object.fromEntries(rows.map(row => [row.id, row])),
  };
};

const search = async ({ append = false } = {}) => {
  if (!props.inboxId) return;
  requestSeq += 1;
  const seq = requestSeq;
  const nextPage = append ? page.value + 1 : 1;
  if (append) {
    loadingMore.value = true;
  } else {
    loading.value = true;
    loadingMore.value = false;
    failed.value = false;
  }

  try {
    const { data } = await CampaignsAPI.whatsappChats(props.inboxId, {
      q: query.value.trim(),
      kind: kind.value,
      page: nextPage,
    });
    if (seq !== requestSeq) return;
    const rows = data.chats || [];
    remember(rows);
    items.value = append ? [...items.value, ...rows] : rows;
    page.value = nextPage;
    hasMore.value = Boolean(data.has_more);
    groupsUnavailable.value = Boolean(data.groups_unavailable);
  } catch {
    if (seq === requestSeq && !append) {
      failed.value = true;
      items.value = [];
    }
  } finally {
    if (seq === requestSeq) {
      loading.value = false;
      loadingMore.value = false;
    }
  }
};

const debouncedSearch = debounce(() => search(), 350, false);
watch(query, () => debouncedSearch());
watch(kind, () => search());

// --- Selección --------------------------------------------------------------
const selectedJids = computed(() => new Set(chats.value));
const permissions = ref({});
const checkingPermissions = ref(false);

const toggle = jid => {
  chats.value = selectedJids.value.has(jid)
    ? chats.value.filter(item => item !== jid)
    : [...chats.value, jid];
};

const permissionOf = jid => {
  if (knownRows.value[jid]?.can_send === true) return true;
  return jid in permissions.value ? permissions.value[jid] : undefined;
};

const chips = computed(() =>
  chats.value.map(jid => {
    const row = knownRows.value[jid];
    return {
      jid,
      name: row?.name || chatNames.value[jid] || jid,
      kind: row?.kind || kindOf(jid),
      permission: permissionOf(jid),
    };
  })
);

const blockedChips = computed(() =>
  chips.value.filter(chip => chip.permission === false)
);
// Solo avisa de los de "solo admins": en el resto no hay nada que comprobar.
const uncheckedChips = computed(() =>
  chips.value.filter(
    chip => chip.permission === null && knownRows.value[chip.jid]?.admins_only
  )
);

const checkPermissions = debounce(
  async () => {
    const pending = chats.value.filter(
      jid => jid.endsWith('@g.us') && permissionOf(jid) === undefined
    );
    if (!props.inboxId || !pending.length) return;
    checkingPermissions.value = true;
    let found = {};
    try {
      const { data } = await CampaignsAPI.whatsappChatPermissions(
        props.inboxId,
        pending
      );
      found = data.permissions || {};
    } catch {
      found = {};
    } finally {
      // Lo que no vuelva (fallo o tope de comprobaciones) queda como "no se
      // sabe" para no repetir la consulta a cada cambio.
      permissions.value = {
        ...permissions.value,
        ...Object.fromEntries(pending.map(jid => [jid, found[jid] ?? null])),
      };
      checkingPermissions.value = false;
    }
  },
  400,
  false
);

watch(
  chats,
  selected => {
    const names = {};
    selected.forEach(jid => {
      names[jid] = knownRows.value[jid]?.name || chatNames.value[jid] || jid;
    });
    chatNames.value = names;
    checkPermissions();
  },
  { immediate: true }
);

// Otra bandeja es otra cuenta de WhatsApp: nada de lo visto vale.
watch(
  () => props.inboxId,
  (inboxId, previousId) => {
    if (previousId && inboxId !== previousId) {
      knownRows.value = {};
      permissions.value = {};
      query.value = '';
    }
    items.value = [];
    if (inboxId) search();
  },
  { immediate: true }
);

const rowMeta = row => {
  const parts = [tr(KIND_LABELS[row.kind] || 'KIND_GROUP')];
  if (row.size) parts.push(tr('MEMBERS', { count: row.size }));
  if (row.admins_only) parts.push(tr('ADMINS_ONLY'));
  return parts.join(' · ');
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <div v-if="chips.length" class="flex flex-wrap gap-1.5">
      <span
        v-for="chip in chips"
        :key="chip.jid"
        class="inline-flex items-center max-w-full min-w-0 gap-1 py-1 pl-2 pr-1 text-xs rounded-md"
        :class="
          chip.permission === false
            ? 'bg-n-amber-3 text-n-amber-11'
            : 'bg-n-alpha-2 text-n-slate-12'
        "
      >
        <span class="flex-shrink-0 size-3.5" :class="KIND_ICONS[chip.kind]" />
        <span class="min-w-0 truncate">{{ chip.name }}</span>
        <button
          type="button"
          class="flex items-center justify-center flex-shrink-0 rounded size-5 text-n-slate-11 hover:bg-n-alpha-3 hover:text-n-slate-12"
          :aria-label="tr('CHATS_REMOVE', { name: chip.name })"
          @click="toggle(chip.jid)"
        >
          <span class="i-lucide-x size-3.5" />
        </button>
      </span>
    </div>

    <p
      v-for="chip in blockedChips"
      :key="`blocked-${chip.jid}`"
      class="mb-0 rounded-md bg-n-amber-2 px-2 py-1 text-xs text-n-amber-11"
    >
      {{ tr('CANNOT_POST_WARNING', { name: chip.name }) }}
    </p>
    <p
      v-for="chip in uncheckedChips"
      :key="`unchecked-${chip.jid}`"
      class="mb-0 text-xs text-n-slate-11"
    >
      {{ tr('CANNOT_CHECK_WARNING', { name: chip.name }) }}
    </p>

    <div class="flex flex-wrap gap-1 p-1 rounded-lg bg-n-alpha-1 self-start">
      <button
        v-for="filter in KIND_FILTERS"
        :key="filter.value"
        type="button"
        class="px-2.5 py-1 text-xs font-medium rounded-md transition-colors"
        :class="
          kind === filter.value
            ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
            : 'text-n-slate-11 hover:text-n-slate-12'
        "
        :aria-pressed="kind === filter.value"
        @click="kind = filter.value"
      >
        {{ tr(filter.label) }}
      </button>
    </div>

    <div class="relative">
      <span
        class="i-lucide-search absolute top-1/2 -translate-y-1/2 ltr:left-3 rtl:right-3 size-4 text-n-slate-10"
      />
      <input
        v-model="query"
        type="search"
        class="!mb-0 ltr:!pl-9 rtl:!pr-9 text-sm"
        :placeholder="tr('CHATS_PLACEHOLDER')"
        :aria-label="tr('CHATS_LABEL')"
      />
    </div>

    <div
      v-if="loading"
      class="flex flex-col items-center gap-2 py-8 text-center"
    >
      <Spinner class="size-5 text-n-slate-10" />
      <p class="mb-0 text-xs text-n-slate-11">{{ tr('CHATS_LOADING') }}</p>
    </div>

    <div
      v-else-if="failed"
      class="flex flex-col items-center gap-2 py-6 text-center"
    >
      <p class="mb-0 text-xs text-n-ruby-11">{{ tr('CHATS_UNAVAILABLE') }}</p>
      <Button
        type="button"
        size="xs"
        variant="faded"
        color="slate"
        icon="i-lucide-refresh-cw"
        :label="tr('CHATS_RETRY')"
        @click="search()"
      />
    </div>

    <p
      v-else-if="!items.length"
      class="py-6 mb-0 text-xs text-center text-n-slate-11"
    >
      {{ query.trim() ? tr('CHATS_NO_RESULTS') : tr('CHATS_EMPTY') }}
    </p>

    <div
      v-else
      class="flex flex-col overflow-y-auto border rounded-lg max-h-72 border-n-weak"
    >
      <button
        v-for="row in items"
        :key="row.id"
        type="button"
        class="flex items-center w-full gap-3 px-3 py-2 text-left border-b border-n-weak last:border-b-0 hover:bg-n-alpha-1"
        :class="{ 'bg-n-alpha-1': selectedJids.has(row.id) }"
        :aria-pressed="selectedJids.has(row.id)"
        @click="toggle(row.id)"
      >
        <span
          class="flex-shrink-0 size-4 text-n-slate-10"
          :class="KIND_ICONS[row.kind]"
        />
        <span class="flex flex-col flex-1 min-w-0">
          <span class="text-sm truncate text-n-slate-12">{{ row.name }}</span>
          <span class="text-xs truncate text-n-slate-11">
            {{ rowMeta(row) }}
          </span>
        </span>
        <span
          class="flex-shrink-0 size-4"
          :class="
            selectedJids.has(row.id)
              ? 'i-lucide-circle-check text-n-teal-11'
              : 'i-lucide-plus text-n-slate-10'
          "
        />
      </button>
      <Button
        v-if="hasMore"
        type="button"
        size="xs"
        variant="ghost"
        color="slate"
        class="self-center my-1"
        :label="tr('CHATS_LOAD_MORE')"
        :is-loading="loadingMore"
        @click="search({ append: true })"
      />
    </div>

    <div
      v-if="groupsUnavailable && !loading && !failed"
      class="flex flex-wrap items-center gap-2 rounded-md bg-n-amber-2 px-2 py-1.5 text-xs text-n-amber-11"
    >
      <span class="min-w-0">{{ tr('CHATS_GROUPS_UNAVAILABLE') }}</span>
      <Button
        type="button"
        variant="link"
        color="amber"
        size="xs"
        :label="tr('CHATS_RETRY')"
        @click="search()"
      />
    </div>

    <p class="mb-0 text-xs text-n-slate-11">
      <span v-if="checkingPermissions">{{ tr('CHATS_CHECKING') }} · </span>
      {{ tr('CHATS_HINT') }}
    </p>
  </div>
</template>
