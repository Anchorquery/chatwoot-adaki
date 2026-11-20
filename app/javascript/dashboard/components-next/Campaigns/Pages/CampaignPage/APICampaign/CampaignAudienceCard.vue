<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';

import CampaignsAPI from 'dashboard/api/campaigns';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import CampaignChatPicker from './CampaignChatPicker.vue';
import {
  buildAudience,
  parsePhoneEntries,
  removePhonesFromText,
} from './campaignAudience';

// Destinatarios de una campaña API: etiquetas (y etiquetas a excluir), grupos,
// comunidades y canales de WhatsApp leídos en directo de la bandeja, y números
// sueltos. Antes de lanzar enseña a cuántos llegaría y deja comprobar qué
// números tienen WhatsApp.
const props = defineProps({
  inboxId: { type: [Number, String], default: null },
  labelOptions: { type: Array, default: () => [] },
  deliverySettings: { type: Object, default: () => ({}) },
  error: { type: String, default: '' },
});

const labelIds = defineModel('labelIds', { type: Array, default: () => [] });
const excludedLabelIds = defineModel('excludedLabelIds', {
  type: Array,
  default: () => [],
});
const chats = defineModel('chats', { type: Array, default: () => [] });
const chatNames = defineModel('chatNames', {
  type: Object,
  default: () => ({}),
});
const phoneText = defineModel('phoneText', { type: String, default: '' });

const { t } = useI18n();
const tr = (key, params) =>
  t(`CAMPAIGN.API.CREATE.FORM.AUDIENCE.${key}`, params);

const TABS = ['LABELS', 'CHATS', 'PHONES'];
const activeTab = ref('LABELS');

// --- Números sueltos --------------------------------------------------------
const phoneEntries = computed(() => parsePhoneEntries(phoneText.value));
const validPhones = computed(() =>
  phoneEntries.value.filter(entry => entry.phone)
);
const invalidPhones = computed(() =>
  phoneEntries.value.filter(entry => !entry.phone)
);
const namedPhones = computed(
  () => validPhones.value.filter(entry => entry.name).length
);

const fileInputRef = ref(null);
const importFile = event => {
  const file = event.target.files?.[0];
  if (!file) return;
  file.text().then(content => {
    phoneText.value = [phoneText.value.trim(), content.trim()]
      .filter(Boolean)
      .join('\n');
  });
  event.target.value = '';
};

// Resultado de la última comprobación, por número (sin "+").
const numberStatus = ref({});
const checkingNumbers = ref(false);
const checkError = ref(false);
const CHECK_CHUNK = 100;

const digitsOf = phone => phone.replace(/\D/g, '');
const uncheckedPhones = computed(() =>
  validPhones.value.filter(
    entry => !(digitsOf(entry.phone) in numberStatus.value)
  )
);
const phonesWithoutWhatsapp = computed(() =>
  validPhones.value.filter(
    entry => numberStatus.value[digitsOf(entry.phone)] === false
  )
);
const checkedCount = computed(
  () => validPhones.value.length - uncheckedPhones.value.length
);

const checkNumbers = async () => {
  if (!props.inboxId || checkingNumbers.value) return;
  checkingNumbers.value = true;
  checkError.value = false;
  const pending = uncheckedPhones.value.map(entry => digitsOf(entry.phone));
  try {
    for (let i = 0; i < pending.length; i += CHECK_CHUNK) {
      // Por tandas: cada número es una consulta a WhatsApp y Evolution corta
      // a los 10 s.
      // eslint-disable-next-line no-await-in-loop
      const { data } = await CampaignsAPI.checkNumbers(
        props.inboxId,
        pending.slice(i, i + CHECK_CHUNK)
      );
      const next = { ...numberStatus.value };
      (data.results || []).forEach(row => {
        next[digitsOf(row.number)] = row.exists;
      });
      numberStatus.value = next;
    }
  } catch {
    checkError.value = true;
  } finally {
    checkingNumbers.value = false;
  }
};

const removeWithoutWhatsapp = () => {
  phoneText.value = removePhonesFromText(
    phoneText.value,
    phonesWithoutWhatsapp.value.map(entry => entry.phone)
  );
};

const removeInvalid = () => {
  const invalid = new Set(invalidPhones.value.map(entry => entry.raw));
  phoneText.value = phoneText.value
    .split('\n')
    .filter(line => !invalid.has(line.trim()))
    .join('\n');
};

// Al cambiar de bandeja, la comprobación (y los chats) ya no valen.
watch(
  () => props.inboxId,
  (inboxId, previousId) => {
    if (previousId && inboxId !== previousId) {
      chats.value = [];
      numberStatus.value = {};
    }
  }
);

// --- Resumen previo ---------------------------------------------------------
const preview = ref(null);
const loadingPreview = ref(false);

const audience = computed(() =>
  buildAudience({
    labelIds: labelIds.value,
    excludedLabelIds: excludedLabelIds.value,
    chats: chats.value,
    chatNames: chatNames.value,
    phoneText: phoneText.value,
  })
);

const hasAnyRecipient = computed(() =>
  audience.value.some(entry => entry.type !== 'ExcludeLabel')
);

const fetchPreview = debounce(
  async () => {
    if (!props.inboxId || !hasAnyRecipient.value) {
      preview.value = null;
      return;
    }
    loadingPreview.value = true;
    try {
      const { data } = await CampaignsAPI.audiencePreview(
        props.inboxId,
        audience.value,
        {
          allow_new_contacts: props.deliverySettings.allow_new_contacts,
          max_new_contacts_per_day:
            props.deliverySettings.max_new_contacts_per_day,
        }
      );
      preview.value = data;
    } catch {
      preview.value = null;
    } finally {
      loadingPreview.value = false;
    }
  },
  600,
  false
);

watch(
  () => [
    props.inboxId,
    JSON.stringify(audience.value),
    props.deliverySettings.allow_new_contacts,
    props.deliverySettings.max_new_contacts_per_day,
  ],
  () => fetchPreview(),
  { immediate: true }
);

const coldDays = computed(() => {
  const data = preview.value;
  if (!data?.allow_new_contacts || !data.cold_contacts) return 0;
  return Math.ceil(data.cold_contacts / (data.daily_new_contacts_limit || 1));
});

const tabCounts = computed(() => ({
  LABELS: labelIds.value.length + excludedLabelIds.value.length,
  CHATS: chats.value.length,
  PHONES: validPhones.value.length,
}));
</script>

<template>
  <div class="flex flex-col gap-3 rounded-xl border border-n-weak p-4">
    <div class="flex flex-wrap items-center justify-between gap-2">
      <p class="mb-0 text-sm font-medium text-n-slate-12">
        {{ tr('CARD_TITLE') }}
      </p>
      <span
        v-if="preview"
        class="rounded-full bg-n-alpha-2 px-2.5 py-0.5 text-xs font-medium text-n-slate-12"
      >
        {{ tr('TOTAL_BADGE', { count: preview.reachable }) }}
      </span>
    </div>

    <div class="flex gap-1 rounded-lg bg-n-alpha-1 p-1">
      <button
        v-for="tab in TABS"
        :key="tab"
        type="button"
        class="flex items-center justify-center flex-1 min-w-0 gap-1 rounded-md px-2 py-1.5 text-xs font-medium leading-tight transition-colors"
        :class="
          activeTab === tab
            ? 'bg-n-solid-1 text-n-slate-12 shadow-sm'
            : 'text-n-slate-11 hover:text-n-slate-12'
        "
        @click="activeTab = tab"
      >
        <span class="min-w-0">{{ tr(`TAB_${tab}`) }}</span>
        <span v-if="tabCounts[tab]" class="flex-shrink-0 text-n-slate-10">
          {{ tabCounts[tab] }}
        </span>
      </button>
    </div>

    <div v-show="activeTab === 'LABELS'" class="flex flex-col gap-3">
      <div class="flex flex-col gap-1">
        <TagMultiSelectComboBox
          v-model="labelIds"
          :options="labelOptions"
          :label="tr('LABEL')"
          :placeholder="tr('PLACEHOLDER')"
          class="[&>div>button]:bg-n-alpha-black2"
        />
        <p class="mb-0 text-xs text-n-slate-11">{{ tr('LABELS_HINT') }}</p>
      </div>
      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ tr('EXCLUDE_LABEL') }}
        </label>
        <TagMultiSelectComboBox
          v-model="excludedLabelIds"
          :options="labelOptions"
          :label="tr('EXCLUDE_LABEL')"
          :placeholder="tr('EXCLUDE_PLACEHOLDER')"
          class="[&>div>button]:bg-n-alpha-black2"
        />
        <p class="mb-0 text-xs text-n-slate-11">{{ tr('EXCLUDE_HINT') }}</p>
      </div>
    </div>

    <div v-show="activeTab === 'CHATS'" class="flex flex-col gap-1">
      <p v-if="!inboxId" class="mb-0 text-xs text-n-slate-11">
        {{ tr('CHATS_NEED_INBOX') }}
      </p>
      <CampaignChatPicker
        v-else
        v-model:chats="chats"
        v-model:chat-names="chatNames"
        :inbox-id="inboxId"
      />
    </div>

    <div v-show="activeTab === 'PHONES'" class="flex flex-col gap-2">
      <TextArea
        v-model="phoneText"
        :label="tr('PHONES_LABEL')"
        :placeholder="tr('PHONES_PLACEHOLDER')"
        :max-length="50000"
        resize
      />
      <!-- Fuera del TextArea: su mensaje se corta a una línea y en móvil no se leía. -->
      <p class="-mt-1 text-xs text-n-slate-11">{{ tr('PHONES_HINT') }}</p>
      <div class="flex flex-wrap items-center gap-2">
        <Button
          type="button"
          variant="faded"
          color="slate"
          size="xs"
          icon="i-lucide-file-up"
          :label="tr('IMPORT_CSV')"
          @click="fileInputRef?.click()"
        />
        <input
          ref="fileInputRef"
          type="file"
          accept=".csv,.txt,text/csv,text/plain"
          class="hidden"
          @change="importFile"
        />
        <Button
          v-if="validPhones.length"
          type="button"
          variant="faded"
          color="blue"
          size="xs"
          :icon="
            checkingNumbers ? 'i-lucide-loader-2' : 'i-lucide-search-check'
          "
          :label="tr('CHECK_NUMBERS', { count: uncheckedPhones.length })"
          :disabled="checkingNumbers || !inboxId || !uncheckedPhones.length"
          @click="checkNumbers"
        />
      </div>
      <p v-if="validPhones.length" class="mb-0 text-xs text-n-slate-11">
        {{ tr('PHONES_COUNT', { count: validPhones.length }) }}
        <template v-if="namedPhones">
          · {{ tr('PHONES_NAMED', { count: namedPhones }) }}
        </template>
        <template v-if="checkedCount">
          · {{ tr('PHONES_CHECKED', { count: checkedCount }) }}
        </template>
      </p>
      <p v-if="checkError" class="mb-0 text-xs text-n-ruby-11">
        {{ tr('CHECK_ERROR') }}
      </p>
      <div
        v-if="phonesWithoutWhatsapp.length"
        class="flex flex-wrap items-center gap-2 rounded-md bg-n-ruby-2 px-2 py-1.5 text-xs text-n-ruby-11"
      >
        <span>
          {{ tr('WITHOUT_WHATSAPP', { count: phonesWithoutWhatsapp.length }) }}
        </span>
        <Button
          type="button"
          variant="link"
          color="ruby"
          size="xs"
          :label="tr('REMOVE_WITHOUT_WHATSAPP')"
          @click="removeWithoutWhatsapp"
        />
      </div>
      <div
        v-if="invalidPhones.length"
        class="flex flex-wrap items-center gap-2 rounded-md bg-n-amber-2 px-2 py-1.5 text-xs text-n-amber-11"
      >
        <span>
          {{
            tr('INVALID_PHONES', {
              count: invalidPhones.length,
              list: invalidPhones
                .slice(0, 3)
                .map(entry => entry.raw)
                .join(', '),
            })
          }}
        </span>
        <Button
          type="button"
          variant="link"
          color="amber"
          size="xs"
          :label="tr('REMOVE_INVALID')"
          @click="removeInvalid"
        />
      </div>
    </div>

    <div
      v-if="preview || loadingPreview"
      class="flex flex-col gap-1 rounded-lg bg-n-alpha-1 px-3 py-2 text-xs text-n-slate-11"
    >
      <p class="mb-0 font-medium text-n-slate-12">
        {{
          loadingPreview && !preview
            ? tr('PREVIEW_LOADING')
            : tr('PREVIEW_TITLE')
        }}
      </p>
      <template v-if="preview">
        <p class="mb-0">
          {{
            tr('PREVIEW_BREAKDOWN', {
              contacts: preview.label_contacts,
              chats: preview.chats,
              phones: preview.phones,
            })
          }}
        </p>
        <p v-if="preview.excluded" class="mb-0">
          {{ tr('PREVIEW_EXCLUDED', { count: preview.excluded }) }}
        </p>
        <p
          v-if="preview.cold_contacts && !preview.allow_new_contacts"
          class="mb-0 text-n-amber-11"
        >
          {{ tr('PREVIEW_COLD_BLOCKED', { count: preview.cold_contacts }) }}
        </p>
        <p v-else-if="preview.cold_contacts" class="mb-0 text-n-amber-11">
          {{
            tr('PREVIEW_COLD_ALLOWED', {
              count: preview.cold_contacts,
              limit: preview.daily_new_contacts_limit,
              days: coldDays,
            })
          }}
        </p>
      </template>
    </div>

    <p v-if="error" class="mb-0 text-xs text-n-ruby-11">{{ error }}</p>
  </div>
</template>
