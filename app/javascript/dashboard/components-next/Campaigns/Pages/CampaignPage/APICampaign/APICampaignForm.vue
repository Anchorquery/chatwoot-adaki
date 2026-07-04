<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import CampaignsAPI from 'dashboard/api/campaigns';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
  selectedCampaign: {
    type: Object,
    default: null,
  },
  showActionButtons: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['submit', 'cancel']);

const { t } = useI18n();

const store = useStore();
const uiFlags = useMapGetter('campaigns/getUIFlags');
const labels = useMapGetter('labels/getLabels');
const inboxes = useMapGetter('inboxes/getApiInboxes');
const captainAssistants = useMapGetter('captainAssistants/getRecords');

const TABS = ['CONTENT', 'VARIANTS', 'FILES', 'DELIVERY'];
const AI_TONES = ['professional', 'friendly', 'casual', 'persuasive'];
const AI_GOALS = ['informative', 'promotional', 'reminder', 'support'];
const AI_STYLES = ['concise', 'standard', 'detailed'];
const AI_CONTEXT_SOURCES = ['none', 'guidelines', 'documents'];

const defaultDeliverySettings = () => ({
  batch_size: 10,
  delay_between_messages_seconds: 3,
  delay_between_batches_seconds: 60,
  max_messages_per_minute: 15,
  max_daily_messages: null,
  max_failures_before_pause: 5,
  pause_on_429: true,
  business_hours_only: false,
  immediate_dispatch: false,
});

const defaultState = () => ({
  title: '',
  message: '',
  inboxId: null,
  scheduledAt: null,
  selectedAudience: [],
  variants: [],
  existingAttachments: [],
  removedExistingAttachmentIds: [],
  attachments: [],
  delivery: defaultDeliverySettings(),
  aiPrompt: '',
  aiTone: 'friendly',
  aiGoal: 'promotional',
  aiAssistantId: null,
  aiContextSource: 'none',
  aiUseEmojis: false,
  aiStyle: 'standard',
});

const state = reactive(defaultState());
const activeTab = ref('CONTENT');
const fileInputRef = ref(null);
const isDragging = ref(false);
const aiLoading = ref(false);

const rules = {
  title: { required, minLength: minLength(1) },
  message: { required, minLength: minLength(1) },
  inboxId: { required },
  scheduledAt: { required },
  selectedAudience: { required },
};

const v$ = useVuelidate(rules, state);

const isCreating = computed(() => uiFlags.value.isCreating);
const isUpdating = computed(() => uiFlags.value.isUpdating);
const isSubmitDisabled = computed(() => v$.value.$invalid);

const mapToOptions = (items, valueKey, labelKey) =>
  items?.map(item => ({ value: item[valueKey], label: item[labelKey] })) ?? [];

const audienceList = computed(() => mapToOptions(labels.value, 'id', 'title'));
const inboxOptions = computed(() => mapToOptions(inboxes.value, 'id', 'name'));
const assistantOptions = computed(() => [
  { value: null, label: t('CAMPAIGN.API.CREATE.FORM.AI.ASSISTANT_NONE') },
  ...mapToOptions(captainAssistants.value, 'id', 'name'),
]);

const currentDateTime = computed(() => {
  const now = new Date();
  return new Date(now.getTime() - now.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
});

const formErrors = computed(() => ({
  title: v$.value.title.$error ? t('CAMPAIGN.API.CREATE.FORM.TITLE.ERROR') : '',
  message: v$.value.message.$error
    ? t('CAMPAIGN.API.CREATE.FORM.MESSAGE.ERROR')
    : '',
  inbox: v$.value.inboxId.$error
    ? t('CAMPAIGN.API.CREATE.FORM.INBOX.ERROR')
    : '',
  scheduledAt: v$.value.scheduledAt.$error
    ? t('CAMPAIGN.API.CREATE.FORM.SCHEDULED_AT.ERROR')
    : '',
  audience: v$.value.selectedAudience.$error
    ? t('CAMPAIGN.API.CREATE.FORM.AUDIENCE.ERROR')
    : '',
}));

const resetState = () => Object.assign(state, defaultState());

const parseLocalDateTime = timestamp => {
  if (!timestamp) return null;
  const date = new Date(Number(timestamp) * 1000);
  return new Date(date.getTime() - date.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
};

const populateFromCampaign = campaign => {
  if (!campaign) return;

  const deliverySettings = campaign.delivery_settings || {};
  const attachments = campaign.attachments || [];

  Object.assign(state, {
    title: campaign.title || '',
    message: campaign.message || '',
    inboxId: campaign.inbox?.id || null,
    scheduledAt: parseLocalDateTime(campaign.scheduled_at),
    selectedAudience: (campaign.audience || [])
      .filter(item => item.type === 'Label')
      .map(item => item.id),
    variants: Array.isArray(deliverySettings.content_variants)
      ? deliverySettings.content_variants
          .map(variant => ({ text: variant?.text || variant || '' }))
          .filter(variant => variant.text.trim())
      : [],
    existingAttachments: attachments,
    removedExistingAttachmentIds: [],
    attachments: [],
    delivery: {
      ...defaultDeliverySettings(),
      ...deliverySettings,
    },
    aiPrompt: '',
    aiTone: 'friendly',
    aiGoal: 'promotional',
    aiAssistantId: null,
    aiContextSource: 'none',
    aiUseEmojis: false,
    aiStyle: 'standard',
  });
};

const handleCancel = () => emit('cancel');

const addVariant = () => state.variants.push({ text: '' });
const removeVariant = index => state.variants.splice(index, 1);

const handleFiles = fileList => {
  Array.from(fileList || []).forEach(file => {
    state.attachments.push({
      file,
      name: file.name,
      url: URL.createObjectURL(file),
    });
  });
};

const onFileChange = event => {
  handleFiles(event.target.files);
  event.target.value = '';
};

const onDrop = event => {
  isDragging.value = false;
  handleFiles(event.dataTransfer.files);
};

const removeAttachment = index => {
  URL.revokeObjectURL(state.attachments[index].url);
  state.attachments.splice(index, 1);
};

const removeExistingAttachment = attachmentId => {
  state.existingAttachments = state.existingAttachments.filter(
    attachment => attachment.id !== attachmentId
  );
  if (!state.removedExistingAttachmentIds.includes(attachmentId)) {
    state.removedExistingAttachmentIds.push(attachmentId);
  }
};

const applyPreset = preset => {
  const presetMap = {
    safe: {
      batch_size: 5,
      delay_between_messages_seconds: 8,
      delay_between_batches_seconds: 180,
      max_messages_per_minute: 8,
      max_daily_messages: 100,
      max_failures_before_pause: 3,
      pause_on_429: true,
      business_hours_only: true,
    },
    balanced: {
      batch_size: 10,
      delay_between_messages_seconds: 3,
      delay_between_batches_seconds: 60,
      max_messages_per_minute: 15,
      max_daily_messages: 250,
      max_failures_before_pause: 5,
      pause_on_429: true,
      business_hours_only: false,
    },
  };

  Object.assign(state.delivery, presetMap[preset] || presetMap.balanced);
};

const buildAiPayload = async () => {
  const { data } = await CampaignsAPI.aiGenerate({
    prompt: state.aiPrompt,
    tone: state.aiTone,
    goal: state.aiGoal,
    assistant_id: state.aiAssistantId,
    context_source: state.aiAssistantId ? state.aiContextSource : 'none',
    use_emojis: state.aiUseEmojis,
    style: state.aiStyle,
  });

  if (data?.title) {
    state.title = data.title;
  }

  if (data?.message) {
    state.message = data.message;
  }

  if (Array.isArray(data?.variants)) {
    state.variants = data.variants.map(variant => ({
      text: variant?.text || variant || '',
    }));
  }
};

const generateWithAI = async () => {
  if (!state.aiPrompt.trim()) return;

  aiLoading.value = true;
  try {
    await buildAiPayload();
  } catch (error) {
    useAlert(
      error?.response?.data?.error ||
        error?.message ||
        t('CAMPAIGN.API.CREATE.FORM.AI.ERROR')
    );
  } finally {
    aiLoading.value = false;
  }
};

const renderWAMarkdown = text =>
  text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\*((?!\s)[\s\S]*?(?<!\s))\*/g, '<strong>$1</strong>')
    .replace(/_((?!\s)[\s\S]*?(?<!\s))_/g, '<em>$1</em>')
    .replace(/~((?!\s)[\s\S]*?(?<!\s))~/g, '<del>$1</del>')
    .replace(
      /`([^`]+)`/g,
      '<code class="bg-n-alpha-3 px-1 rounded text-xs">$1</code>'
    )
    .replace(/\n/g, '<br>');

const waPreviewHtml = computed(() => renderWAMarkdown(state.message));

const formatToUTCString = value =>
  value ? new Date(value).toISOString() : null;

const buildFormData = () => {
  const formData = new FormData();

  formData.append('campaign[title]', state.title);
  formData.append('campaign[message]', state.message);
  formData.append('campaign[inbox_id]', state.inboxId);
  formData.append(
    'campaign[scheduled_at]',
    formatToUTCString(state.scheduledAt)
  );

  state.selectedAudience.forEach(id => {
    formData.append('campaign[audience][][id]', id);
    formData.append('campaign[audience][][type]', 'Label');
  });

  const deliverySettings = {
    ...state.delivery,
    content_variants: state.variants
      .map(variant => variant.text.trim())
      .filter(Boolean)
      .map(text => ({ text })),
  };

  formData.append(
    'campaign[delivery_settings]',
    JSON.stringify(deliverySettings)
  );

  state.removedExistingAttachmentIds.forEach(id => {
    formData.append('campaign[attachment_ids_to_remove][]', id);
  });

  state.attachments.forEach(item => {
    formData.append('campaign[attachments][]', item.file);
  });

  return formData;
};

const prepareCampaignDetails = () => buildFormData();

const handleSubmit = async () => {
  const isValid = await v$.value.$validate();
  if (!isValid) return;

  emit('submit', prepareCampaignDetails());
};

onMounted(() => {
  store.dispatch('captainAssistants/get');
});

watch(
  () => props.selectedCampaign,
  campaign => {
    if (props.mode === 'edit' && campaign) {
      populateFromCampaign(campaign);
    }
  },
  { immediate: true }
);

watch(
  () => props.mode,
  mode => {
    if (mode === 'create') {
      resetState();
    }
  }
);

defineExpose({
  prepareCampaignDetails,
  isSubmitDisabled,
});
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex gap-1 rounded-lg bg-n-alpha-2 p-1">
      <button
        v-for="tab in TABS"
        :key="tab"
        type="button"
        class="flex-1 rounded-md px-2 py-1.5 text-xs font-medium transition-colors"
        :class="
          activeTab === tab
            ? 'bg-n-solid-blue text-white'
            : 'text-n-slate-11 hover:text-n-slate-12'
        "
        @click="activeTab = tab"
      >
        {{ t(`CAMPAIGN.API.TABS.${tab}`) }}
      </button>
    </div>

    <section v-if="activeTab === 'CONTENT'" class="flex flex-col gap-4">
      <div class="flex items-center justify-between gap-3">
        <div class="text-xs text-n-slate-10">
          {{ t('CAMPAIGN.API.CREATE.FORM.AI.HELP') }}
        </div>
      </div>

      <div
        class="flex flex-col gap-2 rounded-xl border border-n-weak bg-n-alpha-2 p-3"
      >
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('CAMPAIGN.API.CREATE.FORM.AI.PROMPT_LABEL') }}
        </label>
        <textarea
          v-model="state.aiPrompt"
          rows="3"
          class="w-full resize-none rounded-lg border border-n-weak bg-n-alpha-black2 px-3 py-2 text-sm text-n-slate-12 outline-none"
          :placeholder="t('CAMPAIGN.API.CREATE.FORM.AI.PROMPT_PLACEHOLDER')"
        />
        <div class="grid gap-3 sm:grid-cols-2">
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.AI.TONE_LABEL') }}
            </label>
            <ComboBox
              v-model="state.aiTone"
              :options="
                AI_TONES.map(tone => ({
                  value: tone,
                  label: t(`CAMPAIGN.API.CREATE.FORM.AI.TONES.${tone}`),
                }))
              "
              :placeholder="t('CAMPAIGN.API.CREATE.FORM.AI.TONE_PLACEHOLDER')"
            />
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.AI.GOAL_LABEL') }}
            </label>
            <ComboBox
              v-model="state.aiGoal"
              :options="
                AI_GOALS.map(goal => ({
                  value: goal,
                  label: t(`CAMPAIGN.API.CREATE.FORM.AI.GOALS.${goal}`),
                }))
              "
              :placeholder="t('CAMPAIGN.API.CREATE.FORM.AI.GOAL_PLACEHOLDER')"
            />
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.AI.ASSISTANT_LABEL') }}
            </label>
            <ComboBox
              v-model="state.aiAssistantId"
              :options="assistantOptions"
              :placeholder="
                t('CAMPAIGN.API.CREATE.FORM.AI.ASSISTANT_PLACEHOLDER')
              "
            />
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.AI.STYLE_LABEL') }}
            </label>
            <ComboBox
              v-model="state.aiStyle"
              :options="
                AI_STYLES.map(s => ({
                  value: s,
                  label: t(`CAMPAIGN.API.CREATE.FORM.AI.STYLES.${s}`),
                }))
              "
              :placeholder="t('CAMPAIGN.API.CREATE.FORM.AI.STYLE_PLACEHOLDER')"
            />
          </div>
          <div
            v-if="state.aiAssistantId"
            class="flex flex-col gap-1 sm:col-span-2"
          >
            <label class="text-xs font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.AI.CONTEXT_SOURCE_LABEL') }}
            </label>
            <ComboBox
              v-model="state.aiContextSource"
              :options="
                AI_CONTEXT_SOURCES.map(s => ({
                  value: s,
                  label: t(`CAMPAIGN.API.CREATE.FORM.AI.CONTEXT_SOURCES.${s}`),
                }))
              "
              :placeholder="
                t('CAMPAIGN.API.CREATE.FORM.AI.CONTEXT_SOURCE_PLACEHOLDER')
              "
            />
          </div>
        </div>
        <label class="flex items-center gap-2 text-sm text-n-slate-11">
          <input v-model="state.aiUseEmojis" type="checkbox" />
          <span>{{ t('CAMPAIGN.API.CREATE.FORM.AI.USE_EMOJIS_LABEL') }}</span>
        </label>
        <div class="flex gap-2">
          <Button
            type="button"
            variant="faded"
            color="slate"
            class="flex-1"
            :label="t('CAMPAIGN.API.CREATE.FORM.AI.CLEAR')"
            @click="state.aiPrompt = ''"
          />
          <Button
            type="button"
            class="flex-1"
            :label="t('CAMPAIGN.API.CREATE.FORM.AI.GENERATE_ALL')"
            :is-loading="aiLoading"
            :disabled="aiLoading || !state.aiPrompt.trim()"
            @click="generateWithAI"
          />
        </div>
      </div>

      <Input
        v-model="state.title"
        :label="t('CAMPAIGN.API.CREATE.FORM.TITLE.LABEL')"
        :placeholder="t('CAMPAIGN.API.CREATE.FORM.TITLE.PLACEHOLDER')"
        :message="formErrors.title"
        :message-type="formErrors.title ? 'error' : 'info'"
      />

      <TextArea
        v-model="state.message"
        :label="t('CAMPAIGN.API.CREATE.FORM.MESSAGE.LABEL')"
        :placeholder="t('CAMPAIGN.API.CREATE.FORM.MESSAGE.PLACEHOLDER')"
        show-character-count
        :max-length="1000"
        auto-height
        min-height="6rem"
        max-height="20rem"
        :message="formErrors.message"
        :message-type="formErrors.message ? 'error' : 'info'"
      />
      <div
        v-if="state.message"
        class="rounded-lg border border-n-weak bg-n-alpha-2 px-3 py-2"
      >
        <p class="mb-1 text-xs font-medium text-n-slate-10">
          {{ t('CAMPAIGN.API.CREATE.FORM.MESSAGE.WA_PREVIEW') }}
        </p>
        <!-- eslint-disable-next-line vue/no-v-html -->
        <div
          class="text-sm text-n-slate-12 whitespace-pre-wrap leading-relaxed"
          v-html="waPreviewHtml"
        />
      </div>

      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('CAMPAIGN.API.CREATE.FORM.INBOX.LABEL') }}
        </label>
        <ComboBox
          v-model="state.inboxId"
          :options="inboxOptions"
          :has-error="!!formErrors.inbox"
          :placeholder="t('CAMPAIGN.API.CREATE.FORM.INBOX.PLACEHOLDER')"
          :message="formErrors.inbox"
          class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
        />
      </div>

      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('CAMPAIGN.API.CREATE.FORM.AUDIENCE.LABEL') }}
        </label>
        <TagMultiSelectComboBox
          v-model="state.selectedAudience"
          :options="audienceList"
          :label="t('CAMPAIGN.API.CREATE.FORM.AUDIENCE.LABEL')"
          :placeholder="t('CAMPAIGN.API.CREATE.FORM.AUDIENCE.PLACEHOLDER')"
          :has-error="!!formErrors.audience"
          :message="formErrors.audience"
          class="[&>div>button]:bg-n-alpha-black2"
        />
      </div>

      <Input
        v-model="state.scheduledAt"
        :label="t('CAMPAIGN.API.CREATE.FORM.SCHEDULED_AT.LABEL')"
        type="datetime-local"
        :min="currentDateTime"
        :placeholder="t('CAMPAIGN.API.CREATE.FORM.SCHEDULED_AT.PLACEHOLDER')"
        :message="formErrors.scheduledAt"
        :message-type="formErrors.scheduledAt ? 'error' : 'info'"
      />
    </section>

    <section v-else-if="activeTab === 'VARIANTS'" class="flex flex-col gap-4">
      <p class="text-xs text-n-slate-10">
        {{ t('CAMPAIGN.API.CREATE.FORM.VARIANTS.HELP') }}
      </p>

      <div class="flex flex-col gap-3">
        <div
          v-for="(variant, index) in state.variants"
          :key="index"
          class="flex items-start gap-2"
        >
          <TextArea
            v-model="variant.text"
            class="flex-1"
            auto-height
            min-height="4rem"
            max-height="16rem"
            :placeholder="
              t('CAMPAIGN.API.CREATE.FORM.VARIANTS.PLACEHOLDER').replace(
                '{num}',
                index + 1
              )
            "
          />
          <Button
            type="button"
            variant="faded"
            color="ruby"
            icon="i-lucide-x"
            @click="removeVariant(index)"
          />
        </div>
      </div>

      <Button
        type="button"
        variant="faded"
        color="slate"
        :label="t('CAMPAIGN.API.CREATE.FORM.VARIANTS.ADD_BUTTON')"
        class="self-start"
        @click="addVariant"
      />
    </section>

    <section v-else-if="activeTab === 'FILES'" class="flex flex-col gap-4">
      <div
        class="rounded-xl border border-dashed border-n-weak p-5 text-center transition-colors"
        :class="
          isDragging ? 'border-n-blue-9 bg-n-blue-3' : 'hover:border-n-blue-7'
        "
        @dragover.prevent="isDragging = true"
        @dragleave="isDragging = false"
        @drop.prevent="onDrop"
        @click="fileInputRef?.click()"
      >
        <p class="text-sm text-n-slate-10">
          {{ t('CAMPAIGN.API.CREATE.FORM.FILES.DROP_LABEL') }}
        </p>
        <input
          ref="fileInputRef"
          type="file"
          multiple
          class="hidden"
          @change="onFileChange"
        />
      </div>

      <div v-if="state.existingAttachments.length" class="flex flex-col gap-2">
        <p class="text-xs font-medium text-n-slate-11">
          {{ t('CAMPAIGN.API.CREATE.FORM.FILES.EXISTING') }}
        </p>
        <div
          v-for="attachment in state.existingAttachments"
          :key="attachment.id"
          class="flex items-center justify-between rounded-lg bg-n-alpha-2 px-3 py-2 text-xs text-n-slate-11"
        >
          <span class="truncate">{{ attachment.filename }}</span>
          <button
            type="button"
            class="text-n-red-10 hover:text-n-red-11"
            @click="removeExistingAttachment(attachment.id)"
          >
            {{ t('CAMPAIGN.API.CREATE.FORM.FILES.REMOVE') }}
          </button>
        </div>
      </div>

      <div v-if="state.attachments.length" class="flex flex-col gap-2">
        <p class="text-xs font-medium text-n-slate-11">
          {{ t('CAMPAIGN.API.CREATE.FORM.FILES.NEW') }}
        </p>
        <div
          v-for="(attachment, index) in state.attachments"
          :key="attachment.url"
          class="flex items-center justify-between rounded-lg bg-n-alpha-2 px-3 py-2 text-xs text-n-slate-11"
        >
          <span class="truncate">{{ attachment.name }}</span>
          <button
            type="button"
            class="text-n-red-10 hover:text-n-red-11"
            @click="removeAttachment(index)"
          >
            {{ t('CAMPAIGN.API.CREATE.FORM.FILES.REMOVE') }}
          </button>
        </div>
      </div>
    </section>

    <section v-else class="flex flex-col gap-4">
      <div class="flex gap-2">
        <button
          type="button"
          class="flex-1 rounded-lg border border-n-weak px-3 py-2 text-xs font-medium text-n-slate-11 hover:bg-n-alpha-3"
          @click="applyPreset('safe')"
        >
          {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.PRESET_SAFE') }}
        </button>
        <button
          type="button"
          class="flex-1 rounded-lg border border-n-weak px-3 py-2 text-xs font-medium text-n-slate-11 hover:bg-n-alpha-3"
          @click="applyPreset('balanced')"
        >
          {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.PRESET_BALANCED') }}
        </button>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.BATCH_SIZE') }}
          </span>
          <Input v-model="state.delivery.batch_size" type="number" min="1" />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.DELAY_MESSAGES') }}
          </span>
          <Input
            v-model="state.delivery.delay_between_messages_seconds"
            type="number"
            min="0"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.DELAY_BATCHES') }}
          </span>
          <Input
            v-model="state.delivery.delay_between_batches_seconds"
            type="number"
            min="0"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.MAX_PER_MINUTE') }}
          </span>
          <Input
            v-model="state.delivery.max_messages_per_minute"
            type="number"
            min="1"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.MAX_DAILY') }}
          </span>
          <Input
            v-model="state.delivery.max_daily_messages"
            type="number"
            min="1"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-xs font-medium text-n-slate-12">
            {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.MAX_FAILURES') }}
          </span>
          <Input
            v-model="state.delivery.max_failures_before_pause"
            type="number"
            min="1"
          />
        </label>
      </div>

      <label class="flex items-center gap-2 text-sm text-n-slate-11">
        <input v-model="state.delivery.pause_on_429" type="checkbox" />
        <span>{{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.PAUSE_ON_429') }}</span>
      </label>

      <label class="flex items-center gap-2 text-sm text-n-slate-11">
        <input v-model="state.delivery.business_hours_only" type="checkbox" />
        <span>{{
          t('CAMPAIGN.API.CREATE.FORM.DELIVERY.BUSINESS_HOURS_ONLY')
        }}</span>
      </label>

      <div
        class="rounded-xl border border-n-weak bg-n-alpha-2 p-3 flex flex-col gap-2"
      >
        <label class="flex items-start gap-3 cursor-pointer">
          <input
            v-model="state.delivery.immediate_dispatch"
            type="checkbox"
            class="mt-0.5"
          />
          <div class="flex flex-col gap-0.5">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('CAMPAIGN.API.CREATE.FORM.DELIVERY.IMMEDIATE_DISPATCH') }}
            </span>
            <span class="text-xs text-n-slate-10">
              {{
                t('CAMPAIGN.API.CREATE.FORM.DELIVERY.IMMEDIATE_DISPATCH_HELP')
              }}
            </span>
          </div>
        </label>
      </div>
    </section>

    <div
      v-if="showActionButtons"
      class="flex items-center justify-between w-full gap-3"
    >
      <Button
        variant="faded"
        color="slate"
        type="button"
        :label="t('CAMPAIGN.API.CREATE.FORM.BUTTONS.CANCEL')"
        class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
        @click="handleCancel"
      />
      <Button
        :label="
          t(
            `CAMPAIGN.API.CREATE.FORM.BUTTONS.${mode === 'edit' ? 'UPDATE' : 'CREATE'}`
          )
        "
        class="w-full"
        type="button"
        :is-loading="isCreating || isUpdating || aiLoading"
        :disabled="isCreating || isUpdating || aiLoading || isSubmitDisabled"
        @click="handleSubmit"
      />
    </div>
  </div>
</template>
