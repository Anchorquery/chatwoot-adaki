<script setup>
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import PrivacyChatRow from './PrivacyChatRow.vue';

const props = defineProps({
  inboxId: {
    type: [String, Number],
    required: true,
  },
  mode: {
    type: String,
    default: 'block',
  },
  selectedJids: {
    type: Set,
    default: () => new Set(),
  },
});

const emit = defineEmits(['add']);

const { t } = useI18n();

const SEARCH_DEBOUNCE_MS = 350;
// Un número de WhatsApp tiene al menos 8 dígitos con prefijo de país.
const MIN_MANUAL_DIGITS = 8;
const TABS = ['contact', 'group', 'channel'];

const type = ref('contact');
const query = ref('');
const items = ref([]);
const page = ref(1);
const hasMore = ref(false);
const loading = ref(false);
const loadingMore = ref(false);
const failed = ref(false);

let debounceTimer = null;
// Descarta respuestas de búsquedas ya superadas: si el admin sigue tecleando,
// una respuesta lenta de "jua" no debe pisar los resultados de "juan".
let requestSeq = 0;

const tabs = computed(() =>
  TABS.map(value => ({
    value,
    label: t(`PRIVACY_FILTER.TYPES.${value.toUpperCase()}`),
  }))
);

const addLabel = computed(() =>
  props.mode === 'allow'
    ? t('PRIVACY_FILTER.SEARCH.ADD_ALLOW')
    : t('PRIVACY_FILTER.SEARCH.ADD_BLOCK')
);

const digits = computed(() => query.value.replace(/\D/g, ''));

// Lo que se escriba a mano también se puede añadir, aparezca o no en los
// resultados: un número con prefijo de país, o un JID de grupo/canal pegado.
const manualItem = computed(() => {
  const text = query.value.trim();
  if (type.value === 'group' && text.endsWith('@g.us')) {
    return { jid: text, name: text, phone: null, type: 'group' };
  }
  if (type.value === 'channel' && text.endsWith('@newsletter')) {
    return { jid: text, name: text, phone: null, type: 'channel' };
  }
  if (type.value !== 'contact' || digits.value.length < MIN_MANUAL_DIGITS) {
    return null;
  }
  if (/[a-z]/i.test(text)) return null;
  const jid = `${digits.value}@s.whatsapp.net`;
  if (items.value.some(item => item.jid === jid)) return null;
  return {
    jid,
    name: `+${digits.value}`,
    phone: digits.value,
    type: 'contact',
  };
});

const search = async ({ append = false } = {}) => {
  requestSeq += 1;
  const seq = requestSeq;
  if (append) loadingMore.value = true;
  else loading.value = true;
  failed.value = false;

  try {
    const nextPage = append ? page.value + 1 : 1;
    const { data } = await InboxesAPI.searchEvolutionPrivacy(props.inboxId, {
      q: query.value.trim(),
      type: type.value,
      page: nextPage,
    });
    if (seq !== requestSeq) return;
    const known = new Set(append ? items.value.map(item => item.jid) : []);
    const fresh = (data.items || []).filter(item => !known.has(item.jid));
    items.value = append ? [...items.value, ...fresh] : fresh;
    page.value = nextPage;
    hasMore.value = Boolean(data.has_more);
  } catch {
    if (seq !== requestSeq) return;
    failed.value = true;
    if (!append) items.value = [];
  } finally {
    if (seq === requestSeq) {
      loading.value = false;
      loadingMore.value = false;
    }
  }
};

watch(query, () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => search(), SEARCH_DEBOUNCE_MS);
});

watch(type, () => {
  clearTimeout(debounceTimer);
  search();
});

const add = item => emit('add', item);

onMounted(() => search());
onBeforeUnmount(() => clearTimeout(debounceTimer));
</script>

<template>
  <section
    class="flex flex-col gap-3 p-4 rounded-2xl border border-n-weak min-h-[24rem]"
  >
    <header class="flex flex-col gap-3">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ $t('PRIVACY_FILTER.SEARCH.TITLE') }}
      </h3>
      <div
        role="tablist"
        class="flex gap-1 p-1 rounded-lg bg-n-alpha-1 self-start"
      >
        <button
          v-for="tab in tabs"
          :key="tab.value"
          type="button"
          role="tab"
          :aria-selected="type === tab.value"
          class="px-3 py-1 text-xs font-medium rounded-md transition-colors"
          :class="
            type === tab.value
              ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
              : 'text-n-slate-11 hover:text-n-slate-12'
          "
          @click="type = tab.value"
        >
          {{ tab.label }}
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
          :placeholder="
            $t(`PRIVACY_FILTER.SEARCH.PLACEHOLDER_${type.toUpperCase()}`)
          "
        />
      </div>
    </header>

    <div
      v-if="manualItem && !selectedJids.has(manualItem.jid)"
      class="flex items-center gap-3 px-3 py-2 rounded-xl bg-n-alpha-1"
    >
      <span class="i-lucide-keyboard size-4 text-n-slate-10 shrink-0" />
      <span class="flex-1 min-w-0 text-sm text-n-slate-12 truncate">
        {{ $t('PRIVACY_FILTER.SEARCH.MANUAL', { value: manualItem.name }) }}
      </span>
      <NextButton
        type="button"
        size="xs"
        icon="i-lucide-plus"
        :label="addLabel"
        @click="add(manualItem)"
      />
    </div>

    <div v-if="loading" class="flex justify-center py-10">
      <Spinner class="size-5 text-n-slate-10" />
    </div>

    <div
      v-else-if="failed"
      class="flex flex-col items-center gap-3 py-10 text-center"
    >
      <p class="text-sm text-n-ruby-11">
        {{ $t('PRIVACY_FILTER.SEARCH.ERROR') }}
      </p>
      <NextButton
        type="button"
        size="sm"
        variant="faded"
        color="slate"
        icon="i-lucide-refresh-cw"
        :label="$t('PRIVACY_FILTER.SEARCH.RETRY')"
        @click="search()"
      />
    </div>

    <p
      v-else-if="!items.length"
      class="py-10 text-sm text-center text-n-slate-11"
    >
      {{
        query.trim()
          ? $t('PRIVACY_FILTER.SEARCH.NO_RESULTS_HINT')
          : $t('PRIVACY_FILTER.SEARCH.EMPTY')
      }}
    </p>

    <div v-else class="flex flex-col overflow-y-auto max-h-[32rem]">
      <PrivacyChatRow
        v-for="item in items"
        :key="item.jid"
        :item="item"
        class="border-b border-n-weak last:border-b-0"
      >
        <template #action>
          <span
            v-if="selectedJids.has(item.jid)"
            class="flex items-center gap-1 text-xs text-n-teal-11 shrink-0"
          >
            <span class="i-lucide-check size-3.5" />
            {{ $t('PRIVACY_FILTER.SEARCH.ADDED') }}
          </span>
          <NextButton
            v-else
            type="button"
            size="xs"
            variant="faded"
            color="slate"
            icon="i-lucide-plus"
            :label="addLabel"
            @click="add(item)"
          />
        </template>
      </PrivacyChatRow>
      <NextButton
        v-if="hasMore"
        type="button"
        size="sm"
        variant="ghost"
        color="slate"
        class="self-center mt-2"
        :label="$t('PRIVACY_FILTER.SEARCH.LOAD_MORE')"
        :is-loading="loadingMore"
        @click="search({ append: true })"
      />
    </div>
  </section>
</template>
