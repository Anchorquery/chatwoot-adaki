<script>
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../../SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import PlatformCredentialsAPI from '../../../../../api/platform/credentials';
import PlatformCredentialModelsAPI from '../../../../../api/platform/credentialModels';
import EditModelModal from './EditModelModal.vue';

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

export default {
  components: {
    SettingsLayout,
    BaseSettingsHeader,
    NextButton,
    EditModelModal,
  },
  props: {
    credentialId: { type: [String, Number], required: true },
  },
  data() {
    return {
      isLoading: false,
      isSyncing: false,
      credential: null,
      models: [],
      search: '',
      activeKind: 'all',
      togglingId: null,
      bulkLoading: false,
      showEditModal: false,
      editingModel: null,
    };
  },
  computed: {
    filteredModels() {
      const q = this.search.trim().toLowerCase();
      return this.models.filter(m => {
        if (this.activeKind !== 'all' && m.kind !== this.activeKind)
          return false;
        if (!q) return true;
        return (
          (m.display_name || '').toLowerCase().includes(q) ||
          (m.slug || '').toLowerCase().includes(q)
        );
      });
    },
    enabledCount() {
      return this.models.filter(m => m.enabled).length;
    },
    kindCounts() {
      const counts = { all: this.models.length };
      KINDS.forEach(k => {
        counts[k] = 0;
      });
      this.models.forEach(m => {
        counts[m.kind] = (counts[m.kind] || 0) + 1;
      });
      return counts;
    },
    kindTabs() {
      return [
        { value: 'all', label: this.$t('ADAKI.CAPTAIN.MODELS.KINDS.ALL') },
      ].concat(
        KINDS.map(k => ({
          value: k,
          label: this.$t(`ADAKI.CAPTAIN.MODELS.KINDS.${k.toUpperCase()}`),
        }))
      );
    },
  },
  mounted() {
    this.fetchAll();
  },
  methods: {
    async fetchAll() {
      this.isLoading = true;
      try {
        const [{ data: credential }, { data: models }] = await Promise.all([
          PlatformCredentialsAPI.show(this.credentialId),
          PlatformCredentialModelsAPI.index(this.credentialId),
        ]);
        this.credential = credential;
        this.models = models;
      } catch (error) {
        useAlert(
          error.message || this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.LOAD_ERROR')
        );
      } finally {
        this.isLoading = false;
      }
    },
    async fetchModels() {
      const { data } = await PlatformCredentialModelsAPI.index(
        this.credentialId
      );
      this.models = data;
    },
    async syncModels() {
      this.isSyncing = true;
      try {
        const { data } = await PlatformCredentialModelsAPI.sync(
          this.credentialId
        );
        useAlert(
          this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.SYNCED', {
            total: data?.imported ?? 0,
          })
        );
        await this.fetchModels();
      } catch (error) {
        const msg =
          error.response?.data?.error ||
          error.message ||
          this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.SYNC_ERROR');
        useAlert(msg);
      } finally {
        this.isSyncing = false;
      }
    },
    async toggleModel(model) {
      this.togglingId = model.id;
      try {
        const { data } = await PlatformCredentialModelsAPI.toggle(
          this.credentialId,
          model.id
        );
        const idx = this.models.findIndex(m => m.id === data.id);
        if (idx >= 0) this.models.splice(idx, 1, data);
      } catch (error) {
        useAlert(
          error.message || this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.TOGGLE_ERROR')
        );
      } finally {
        this.togglingId = null;
      }
    },
    async bulkToggle(enabled) {
      this.bulkLoading = true;
      try {
        const kind = this.activeKind === 'all' ? null : this.activeKind;
        await PlatformCredentialModelsAPI.bulkToggle(this.credentialId, {
          enabled,
          kind,
        });
        await this.fetchModels();
      } catch (error) {
        useAlert(
          error.message || this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.TOGGLE_ERROR')
        );
      } finally {
        this.bulkLoading = false;
      }
    },
    openEdit(model) {
      this.editingModel = {
        ...model,
        capabilities: [...(model.capabilities || [])],
        reasoning_config: { ...(model.reasoning_config || {}) },
      };
      this.showEditModal = true;
    },
    reasoningSummary(model) {
      const efforts = model.reasoning_config?.supported_efforts;
      if (!Array.isArray(efforts)) return '';
      if (!efforts.length) {
        return this.$t('ADAKI.CAPTAIN.MODELS.REASONING_NONE');
      }
      return `${this.$t('ADAKI.CAPTAIN.MODELS.REASONING_LABEL')}: ${efforts.join(' · ')}`;
    },
    closeEdit() {
      this.showEditModal = false;
      this.editingModel = null;
    },
    async saveEdit(payload) {
      try {
        const { data } = await PlatformCredentialModelsAPI.update(
          this.credentialId,
          this.editingModel.id,
          payload
        );
        const idx = this.models.findIndex(m => m.id === data.id);
        if (idx >= 0) this.models.splice(idx, 1, data);
        useAlert(this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.UPDATED'));
        this.closeEdit();
      } catch (error) {
        useAlert(
          error.message || this.$t('ADAKI.CAPTAIN.MODELS.ALERTS.UPDATE_ERROR')
        );
      }
    },
    backToProviders() {
      this.$router.push({
        name: 'adaki_providers_index',
        params: { accountId: this.$route.params.accountId },
      });
    },
    formatPrice(value) {
      if (value === null || value === undefined || value === '') return '';
      const n = Number(value);
      if (Number.isNaN(n)) return '';
      return `$${n.toFixed(2)}/1M`;
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="isLoading">
    <template #header>
      <BaseSettingsHeader
        :title="credential ? credential.name : ''"
        :description="
          credential
            ? `${credential.provider} · ${enabledCount} ${$t('ADAKI.CAPTAIN.MODELS.ACTIVE_COUNT')}`
            : ''
        "
        :show-back-button="false"
      />
    </template>
    <template #body>
      <div class="max-w-6xl">
        <button
          type="button"
          class="mb-4 inline-flex items-center gap-1 text-sm text-n-slate-11 hover:text-n-slate-12"
          @click="backToProviders"
        >
          <span class="i-lucide-arrow-left" />
          {{ $t('ADAKI.CAPTAIN.MODELS.BACK') }}
        </button>

        <div class="mb-4 flex flex-wrap items-center gap-2">
          <button
            v-for="tab in kindTabs"
            :key="tab.value"
            type="button"
            class="rounded-full px-3 py-1 text-sm transition"
            :class="
              activeKind === tab.value
                ? 'bg-n-brand text-white'
                : 'bg-n-slate-3 text-n-slate-12 hover:bg-n-slate-4'
            "
            @click="activeKind = tab.value"
          >
            {{ tab.label }} ({{ kindCounts[tab.value] || 0 }})
          </button>
        </div>

        <div class="mb-3 flex flex-wrap items-center gap-2">
          <input
            v-model="search"
            type="text"
            class="form-input flex-1 min-w-[200px]"
            :placeholder="$t('ADAKI.CAPTAIN.MODELS.SEARCH_PLACEHOLDER')"
          />
          <NextButton
            :label="$t('ADAKI.CAPTAIN.MODELS.SYNC')"
            sm
            slate
            icon="i-lucide-refresh-cw"
            :is-loading="isSyncing"
            @click="syncModels"
          />
        </div>

        <div class="mb-2 flex gap-3 text-sm">
          <button
            type="button"
            class="text-n-slate-11 hover:text-n-slate-12 disabled:opacity-50"
            :disabled="bulkLoading"
            @click="bulkToggle(true)"
          >
            {{ $t('ADAKI.CAPTAIN.MODELS.ENABLE_ALL') }}
          </button>
          <button
            type="button"
            class="text-n-slate-11 hover:text-n-slate-12 disabled:opacity-50"
            :disabled="bulkLoading"
            @click="bulkToggle(false)"
          >
            {{ $t('ADAKI.CAPTAIN.MODELS.DISABLE_ALL') }}
          </button>
        </div>

        <div
          v-if="!filteredModels.length"
          class="rounded-lg border border-dashed border-n-weak p-6 text-center text-sm text-n-slate-11"
        >
          {{ $t('ADAKI.CAPTAIN.MODELS.EMPTY') }}
        </div>

        <div v-else class="flex flex-col gap-2">
          <div
            v-for="model in filteredModels"
            :key="model.id"
            class="flex items-start gap-3 rounded-lg border border-n-weak p-3"
          >
            <span
              class="mt-0.5 shrink-0 rounded-md bg-n-slate-3 px-2 py-0.5 text-xs text-n-slate-12 capitalize"
            >
              {{ model.kind }}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span class="font-medium text-n-slate-12 truncate">{{
                  model.display_name
                }}</span>
                <span
                  v-if="model.obsolete"
                  class="rounded bg-n-amber-2 px-1.5 py-0.5 text-xs text-n-amber-11"
                >
                  {{ $t('ADAKI.CAPTAIN.MODELS.OBSOLETE') }}
                </span>
              </div>
              <div class="font-mono text-xs text-n-slate-10">
                {{ model.slug }}
              </div>
              <div
                class="mt-1 flex flex-wrap items-center gap-2 text-xs text-n-slate-11"
              >
                <span v-if="model.context_window">{{
                  $t('ADAKI.CAPTAIN.MODELS.CONTEXT_WINDOW_LABEL', {
                    tokens: Math.round(model.context_window / 1000),
                  })
                }}</span>
                <span v-if="model.max_output_tokens">{{
                  $t('ADAKI.CAPTAIN.MODELS.MAX_OUTPUT_LABEL', {
                    tokens: Math.round(model.max_output_tokens / 1000),
                  })
                }}</span>
                <span v-if="model.input_price_per_million">{{
                  $t('ADAKI.CAPTAIN.MODELS.INPUT_PRICE_LABEL', {
                    price: formatPrice(model.input_price_per_million),
                  })
                }}</span>
                <span v-if="model.output_price_per_million">{{
                  $t('ADAKI.CAPTAIN.MODELS.OUTPUT_PRICE_LABEL', {
                    price: formatPrice(model.output_price_per_million),
                  })
                }}</span>
                <span
                  v-for="cap in model.capabilities"
                  :key="cap"
                  class="rounded bg-n-slate-3 px-1.5 py-0.5"
                >
                  {{ cap }}</span
                >
                <span
                  v-if="reasoningSummary(model)"
                  class="rounded bg-n-iris-3 px-1.5 py-0.5 text-n-iris-11"
                  :title="
                    model.reasoning_config && model.reasoning_config.source
                      ? $t(
                          `ADAKI.CAPTAIN.MODELS.REASONING_SOURCE.${model.reasoning_config.source.toUpperCase()}`
                        )
                      : ''
                  "
                >
                  {{ reasoningSummary(model) }}
                </span>
              </div>
              <p
                v-if="model.description"
                class="mt-1 text-xs text-n-slate-11 line-clamp-2"
              >
                {{ model.description }}
              </p>
            </div>
            <NextButton
              icon="i-lucide-pencil-line"
              size="xs"
              slate
              ghost
              @click="openEdit(model)"
            />
            <button
              type="button"
              class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors"
              :class="model.enabled ? 'bg-n-teal-9' : 'bg-n-slate-6'"
              :disabled="togglingId === model.id"
              @click="toggleModel(model)"
            >
              <span
                class="inline-block h-5 w-5 transform rounded-full bg-white transition-transform"
                :class="model.enabled ? 'translate-x-5' : 'translate-x-1'"
              />
            </button>
          </div>
        </div>
      </div>

      <EditModelModal
        v-if="showEditModal && editingModel"
        :show="showEditModal"
        :model-data="editingModel"
        @close="closeEdit"
        @save="saveEdit"
      />
    </template>
  </SettingsLayout>
</template>
