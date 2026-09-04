<script>
import NextButton from 'dashboard/components-next/button/Button.vue';

const KINDS = [
  'chat',
  'multimodal',
  'embedding',
  'image',
  'tts',
  'transcription',
  'realtime',
  'video',
  'web_search',
];
const CAPABILITIES = [
  'multimodal',
  'image_gen',
  'embedding',
  'transcription',
  'tts',
  'video_gen',
  'web_search',
  'tools',
  'thinking',
  'code',
  'json',
  'vision',
];
// Reasoning efforts the provider accepts for this model, lowest to highest
// (OpenRouter/OpenAI vocabulary). Captain maps "off" to the lowest one.
const REASONING_EFFORTS = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'];

export default {
  components: { NextButton },
  props: {
    show: { type: Boolean, default: false },
    modelData: { type: Object, required: true },
  },
  emits: ['close', 'save'],
  data() {
    return {
      form: this.cloneModel(this.modelData),
    };
  },
  computed: {
    kindOptions() {
      return KINDS.map(k => ({
        value: k,
        label: this.$t(`ADAKI.CAPTAIN.MODELS.KINDS.${k.toUpperCase()}`),
      }));
    },
    capabilityOptions() {
      return CAPABILITIES;
    },
    reasoningEffortOptions() {
      return REASONING_EFFORTS;
    },
    reasoningSourceLabel() {
      const source = this.modelData?.reasoning_config?.source;
      if (!source) return '';
      return this.$t(
        `ADAKI.CAPTAIN.MODELS.REASONING_SOURCE.${source.toUpperCase()}`
      );
    },
  },
  watch: {
    modelData: {
      handler(val) {
        this.form = this.cloneModel(val);
      },
      deep: true,
    },
  },
  methods: {
    cloneModel(model) {
      return {
        slug: model.slug || '',
        display_name: model.display_name || '',
        kind: model.kind || 'chat',
        capabilities: [...(model.capabilities || [])],
        context_window: model.context_window ?? null,
        max_output_tokens: model.max_output_tokens ?? null,
        input_price_per_million: model.input_price_per_million ?? null,
        output_price_per_million: model.output_price_per_million ?? null,
        data_cutoff_at: model.data_cutoff_at || '',
        description: model.description || '',
        obsolete: Boolean(model.obsolete),
        reasoning_efforts: [
          ...((model.reasoning_config &&
            model.reasoning_config.supported_efforts) ||
            []),
        ],
      };
    },
    toggleCapability(cap) {
      const idx = this.form.capabilities.indexOf(cap);
      if (idx >= 0) this.form.capabilities.splice(idx, 1);
      else this.form.capabilities.push(cap);
    },
    toggleReasoningEffort(effort) {
      const idx = this.form.reasoning_efforts.indexOf(effort);
      if (idx >= 0) this.form.reasoning_efforts.splice(idx, 1);
      else this.form.reasoning_efforts.push(effort);
    },
    submit() {
      const { reasoning_efforts: reasoningEfforts, ...rest } = this.form;
      this.$emit('save', {
        ...rest,
        reasoning_config: {
          supported_efforts: REASONING_EFFORTS.filter(e =>
            reasoningEfforts.includes(e)
          ),
        },
      });
    },
    close() {
      this.$emit('close');
    },
  },
};
</script>

<template>
  <woot-modal :show="show" size="medium" :on-close="close">
    <form class="w-full p-6" autocomplete="off" @submit.prevent="submit">
      <div class="mb-5 flex items-start justify-between gap-4">
        <h2 class="text-heading-2">
          {{ $t('ADAKI.CAPTAIN.MODELS.MODAL.EDIT_TITLE') }}
        </h2>
      </div>

      <label class="mb-4 flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.CAPTAIN.MODELS.MODAL.SLUG')
        }}</span>
        <input
          v-model="form.slug"
          class="form-input"
          type="text"
          autocomplete="off"
        />
      </label>

      <div class="mb-3 text-xs uppercase tracking-wide text-n-slate-10">
        {{ $t('ADAKI.CAPTAIN.MODELS.MODAL.BASIC') }}
      </div>

      <label class="mb-4 flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.CAPTAIN.MODELS.MODAL.DISPLAY_NAME')
        }}</span>
        <input
          v-model="form.display_name"
          class="form-input"
          type="text"
          autocomplete="off"
        />
      </label>

      <div class="mb-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.KIND')
          }}</span>
          <select v-model="form.kind" class="form-input">
            <option v-for="o in kindOptions" :key="o.value" :value="o.value">
              {{ o.label }}
            </option>
          </select>
        </label>
        <label class="flex items-center gap-2 pt-6">
          <input v-model="form.obsolete" type="checkbox" />
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.OBSOLETE')
          }}</span>
        </label>
      </div>

      <div class="mb-2 text-body-main">
        {{ $t('ADAKI.CAPTAIN.MODELS.MODAL.CAPABILITIES') }}
        <span class="text-xs text-n-slate-10">{{
          $t('ADAKI.CAPTAIN.MODELS.MODAL.CAPABILITIES_HINT')
        }}</span>
      </div>
      <div class="mb-4 grid grid-cols-2 gap-2 md:grid-cols-3">
        <label
          v-for="cap in capabilityOptions"
          :key="cap"
          class="flex items-center gap-2 text-sm"
        >
          <input
            type="checkbox"
            :checked="form.capabilities.includes(cap)"
            @change="toggleCapability(cap)"
          />
          <span>{{ cap }}</span>
        </label>
      </div>

      <div class="mb-2 text-body-main">
        {{ $t('ADAKI.CAPTAIN.MODELS.MODAL.REASONING') }}
        <span class="text-xs text-n-slate-10">{{
          $t('ADAKI.CAPTAIN.MODELS.MODAL.REASONING_HINT')
        }}</span>
      </div>
      <div class="mb-1 grid grid-cols-3 gap-2 md:grid-cols-6">
        <label
          v-for="effort in reasoningEffortOptions"
          :key="effort"
          class="flex items-center gap-2 text-sm"
        >
          <input
            type="checkbox"
            :checked="form.reasoning_efforts.includes(effort)"
            @change="toggleReasoningEffort(effort)"
          />
          <span class="font-mono">{{ effort }}</span>
        </label>
      </div>
      <p v-if="reasoningSourceLabel" class="mb-4 text-xs text-n-slate-10">
        {{ reasoningSourceLabel }}
      </p>
      <div v-else class="mb-4" />

      <label class="mb-4 flex flex-col gap-1">
        <span class="text-body-main">{{
          $t('ADAKI.CAPTAIN.MODELS.MODAL.DESCRIPTION')
        }}</span>
        <input
          v-model="form.description"
          class="form-input"
          type="text"
          autocomplete="off"
        />
      </label>

      <div class="mb-3 text-xs uppercase tracking-wide text-n-slate-10">
        {{ $t('ADAKI.CAPTAIN.MODELS.MODAL.LIMITS_PRICING') }}
      </div>

      <div class="mb-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.CONTEXT_MAX')
          }}</span>
          <input
            v-model.number="form.context_window"
            class="form-input"
            type="number"
            min="0"
            autocomplete="off"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.OUTPUT_MAX')
          }}</span>
          <input
            v-model.number="form.max_output_tokens"
            class="form-input"
            type="number"
            min="0"
            autocomplete="off"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.INPUT_PRICE')
          }}</span>
          <input
            v-model.number="form.input_price_per_million"
            class="form-input"
            type="number"
            step="0.0001"
            min="0"
            autocomplete="off"
          />
        </label>
        <label class="flex flex-col gap-1">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.OUTPUT_PRICE')
          }}</span>
          <input
            v-model.number="form.output_price_per_million"
            class="form-input"
            type="number"
            step="0.0001"
            min="0"
            autocomplete="off"
          />
        </label>
        <label class="flex flex-col gap-1 md:col-span-2">
          <span class="text-body-main">{{
            $t('ADAKI.CAPTAIN.MODELS.MODAL.DATA_CUTOFF')
          }}</span>
          <input
            v-model="form.data_cutoff_at"
            class="form-input"
            type="date"
            autocomplete="off"
          />
        </label>
      </div>

      <div class="mt-6 flex justify-end gap-2">
        <NextButton
          type="button"
          :label="$t('ADAKI.CAPTAIN.MODELS.MODAL.CANCEL')"
          sm
          slate
          @click="close"
        />
        <NextButton
          type="submit"
          :label="$t('ADAKI.CAPTAIN.MODELS.MODAL.SAVE')"
          sm
        />
      </div>
    </form>
  </woot-modal>
</template>
