<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../../SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';
import WootLabel from 'dashboard/components-next/label/Label.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

function buildEmptyCredentialForm(provider) {
  return {
    provider,
    purpose: 'ai_provider',
    key: '',
    name: '',
    auth_type: 'api_key',
    metadata: {
      api_base: '',
      model: '',
    },
    secrets: {
      api_key: '',
      token: '',
      username: '',
      password: '',
      access_token: '',
      refresh_token: '',
      client_id: '',
      client_secret: '',
      custom_json: '',
    },
  };
}

export default {
  components: {
    SettingsLayout,
    BaseSettingsHeader,
    BaseTable,
    BaseTableRow,
    BaseTableCell,
    WootLabel,
    NextButton,
  },
  data() {
    return {
      limit: '',
      showCredentialModal: false,
      editingCredentialId: null,
      originalAuthType: null,
      credentialActionLoading: {
        validate: null,
        revoke: null,
        destroy: null,
      },
      credentialForm: buildEmptyCredentialForm('openai'),
    };
  },
  computed: {
    ...mapGetters({
      settings: 'adakiCaptainSettings/getSettings',
      uiFlags: 'adakiCaptainSettings/getUIFlags',
      credentials: 'adakiCaptainSettings/getCredentials',
    }),
    usagePct() {
      if (!this.settings?.adaki_captain_monthly_limit) return null;
      return Math.round((this.settings.request_count / this.settings.adaki_captain_monthly_limit) * 100);
    },
    providerOptions() {
      const providers = this.settings?.providers || {};
      return Object.entries(providers).map(([value, meta]) => ({
        value,
        label: meta.display_name || value,
      }));
    },
    modelOptions() {
      const models = this.settings?.models || {};
      return Object.entries(models)
        .filter(([, meta]) => meta.provider === this.credentialForm.provider)
        .map(([value, meta]) => ({
          value,
          label: meta.display_name || value,
          comingSoon: Boolean(meta.coming_soon),
        }));
    },
    credentialHeaders() {
      return [
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.NAME'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.PROVIDER'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.MODEL'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.PURPOSE'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.AUTH'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.STATUS'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.LAST_USED'),
        this.$t('ADAKI.CAPTAIN.CREDENTIALS.TABLE.ACTIONS'),
      ];
    },
    authTypeOptions() {
      return [
        { value: 'api_key', label: this.$t('ADAKI.CAPTAIN.CREDENTIALS.AUTH_TYPES.API_KEY') },
        { value: 'bearer', label: this.$t('ADAKI.CAPTAIN.CREDENTIALS.AUTH_TYPES.BEARER') },
        { value: 'basic', label: this.$t('ADAKI.CAPTAIN.CREDENTIALS.AUTH_TYPES.BASIC') },
        { value: 'oauth2', label: this.$t('ADAKI.CAPTAIN.CREDENTIALS.AUTH_TYPES.OAUTH2') },
        { value: 'custom_json', label: this.$t('ADAKI.CAPTAIN.CREDENTIALS.AUTH_TYPES.CUSTOM_JSON') },
      ];
    },
    isEditingCredential() {
      return Boolean(this.editingCredentialId);
    },
    credentialModalTitle() {
      return this.isEditingCredential
        ? this.$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.EDIT_TITLE')
        : this.$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.NEW_TITLE');
    },
  },
  watch: {
    settings: {
      immediate: true,
      handler(val) {
        if (!val) return;
        this.limit = val.adaki_captain_monthly_limit ?? '';

        if (!this.providerOptions.length) return;

        if (!this.providerOptions.find(option => option.value === this.credentialForm.provider)) {
          this.credentialForm.provider = this.providerOptions[0].value;
        }
      },
    },
    'credentialForm.provider': function onCredentialProviderChange(provider) {
      if (!this.modelOptions.length) {
        this.credentialForm.metadata.model = '';
        return;
      }

      const hasCurrentModel = this.modelOptions.some(option => option.value === this.credentialForm.metadata.model);
      if (!hasCurrentModel) {
        this.credentialForm.metadata.model = this.defaultModelForProvider(provider);
      }
    },
  },
  mounted() {
    this.$store.dispatch('adakiCaptainSettings/fetch');
  },
  methods: {
    defaultProvider() {
      return this.providerOptions[0]?.value || 'openai';
    },
    defaultModelForProvider(provider) {
      return this.modelOptionsForProvider(provider)[0]?.value || '';
    },
    modelOptionsForProvider(provider) {
      const models = this.settings?.models || {};
      return Object.entries(models)
        .filter(([, meta]) => meta.provider === provider)
        .map(([value, meta]) => ({
          value,
          label: meta.display_name || value,
          comingSoon: Boolean(meta.coming_soon),
        }));
    },
    providerLabel(provider) {
      return this.providerOptions.find(option => option.value === provider)?.label || provider || '-';
    },
    modelLabel(model) {
      if (!model) return '-';
      return this.settings?.models?.[model]?.display_name || model;
    },
    authTypeLabel(authType) {
      const option = this.authTypeOptions.find(item => item.value === authType);
      return option?.label || authType || '-';
    },
    statusLabel(status) {
      return (
        {
          active: this.$t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.ACTIVE'),
          invalid: this.$t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.INVALID'),
          expired: this.$t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.EXPIRED'),
          revoked: this.$t('ADAKI.CAPTAIN.CREDENTIALS.STATUS.REVOKED'),
        }[status] || status || '-'
      );
    },
    statusColor(status) {
      return (
        {
          active: 'teal',
          invalid: 'amber',
          expired: 'amber',
          revoked: 'ruby',
        }[status] || 'slate'
      );
    },
    formatDate(value) {
      return value ? new Date(value).toLocaleString() : '-';
    },
    resetCredentialForm(provider = this.defaultProvider()) {
      this.credentialForm = buildEmptyCredentialForm(provider);
    },
    openCreateCredential() {
      this.editingCredentialId = null;
      this.resetCredentialForm(this.defaultProvider());
      this.showCredentialModal = true;
    },
    openEditCredential(credential) {
      this.editingCredentialId = credential.id;
      this.originalAuthType = credential.auth_type || 'api_key';
      const provider = credential.provider || this.defaultProvider();
      const model = credential.metadata?.model || this.defaultModelForProvider(provider);

      this.credentialForm = {
        provider,
        purpose: credential.purpose || 'ai_provider',
        key: credential.key || '',
        name: credential.name || '',
        auth_type: credential.auth_type || 'api_key',
        metadata: {
          api_base: credential.metadata?.api_base || '',
          model,
        },
        secrets: {
          api_key: '',
          token: '',
          username: '',
          password: '',
          access_token: '',
          refresh_token: '',
          client_id: '',
          client_secret: '',
          custom_json: '',
        },
      };

      this.showCredentialModal = true;
    },
    closeCredentialModal() {
      this.showCredentialModal = false;
      this.editingCredentialId = null;
      this.originalAuthType = null;
      this.resetCredentialForm(this.defaultProvider());
    },
    secretPayload() {
      const form = this.credentialForm;

      switch (form.auth_type) {
        case 'bearer':
          return form.secrets.token.trim() ? { token: form.secrets.token.trim() } : null;
        case 'basic':
          return form.secrets.username.trim() || form.secrets.password.trim()
            ? {
              username: form.secrets.username.trim(),
              password: form.secrets.password,
            }
            : null;
        case 'oauth2':
          return form.secrets.access_token.trim() ||
            form.secrets.refresh_token.trim() ||
            form.secrets.client_id.trim() ||
            form.secrets.client_secret.trim()
            ? {
              access_token: form.secrets.access_token.trim(),
              refresh_token: form.secrets.refresh_token.trim(),
              client_id: form.secrets.client_id.trim(),
              client_secret: form.secrets.client_secret,
            }
            : null;
        case 'custom_json':
          if (!form.secrets.custom_json.trim()) return null;
          try {
            const parsed = JSON.parse(form.secrets.custom_json);
            return parsed && typeof parsed === 'object' ? parsed : null;
          } catch (_error) {
            throw new Error(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.INVALID_JSON'));
          }
        case 'api_key':
        default:
          return form.secrets.api_key.trim() ? { api_key: form.secrets.api_key.trim() } : null;
      }
    },
    async saveCredential() {
      try {
        const payload = this.secretPayload();
        if (!this.isEditingCredential && !payload) {
          useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.SECRET_REQUIRED'));
          return;
        }

        if (this.isEditingCredential && this.originalAuthType !== this.credentialForm.auth_type && !payload) {
          useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.SECRET_REQUIRED'));
          return;
        }

        const credential = {
          provider: this.credentialForm.provider,
          purpose: this.credentialForm.purpose,
          key: this.credentialForm.key || undefined,
          name: this.credentialForm.name,
          auth_type: this.credentialForm.auth_type,
          metadata: {
            api_base: this.credentialForm.metadata.api_base || null,
            model: this.credentialForm.metadata.model || null,
          },
        };

        if (payload) {
          credential.payload = payload;
        }

        if (this.isEditingCredential) {
          await this.$store.dispatch('adakiCaptainSettings/updateCredential', {
            id: this.editingCredentialId,
            payload: credential,
          });
          useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.UPDATED'));
        } else {
          await this.$store.dispatch('adakiCaptainSettings/createCredential', credential);
          useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.CREATED'));
        }

        this.closeCredentialModal();
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR'));
      }
    },
    async validateCredential(credential) {
      this.credentialActionLoading = {
        ...this.credentialActionLoading,
        validate: credential.id,
      };

      try {
        await this.$store.dispatch('adakiCaptainSettings/validateCredential', credential.id);
        useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.VALIDATED'));
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR'));
      } finally {
        this.credentialActionLoading = {
          ...this.credentialActionLoading,
          validate: null,
        };
      }
    },
    async revokeCredential(credential) {
      this.credentialActionLoading = {
        ...this.credentialActionLoading,
        revoke: credential.id,
      };

      try {
        await this.$store.dispatch('adakiCaptainSettings/revokeCredential', credential.id);
        useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.REVOKED'));
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR'));
      } finally {
        this.credentialActionLoading = {
          ...this.credentialActionLoading,
          revoke: null,
        };
      }
    },
    async destroyCredential(credential) {
      const confirmed = window.confirm(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.DELETE_CONFIRM'));
      if (!confirmed) return;

      this.credentialActionLoading = {
        ...this.credentialActionLoading,
        destroy: credential.id,
      };

      try {
        await this.$store.dispatch('adakiCaptainSettings/destroyCredential', credential.id);
        useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.DELETED'));
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR'));
      } finally {
        this.credentialActionLoading = {
          ...this.credentialActionLoading,
          destroy: null,
        };
      }
    },
    rowModels(credential) {
      return this.modelLabel(credential.metadata?.model);
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching" :loading-message="$t('ADAKI.CAPTAIN.LOADING')">
    <template #header>
      <BaseSettingsHeader
        :title="$t('ADAKI.CAPTAIN.HEADER')"
        :description="$t('ADAKI.CAPTAIN.DESCRIPTION')"
        :show-back-button="false"
      />
    </template>
    <template #body>
      <div class="flex max-w-5xl flex-col gap-6">
        <section class="rounded-lg border border-n-weak p-4">
          <h3 class="mb-2 text-heading-3">{{ $t('ADAKI.CAPTAIN.LIMIT_TITLE') }}</h3>
          <p class="mb-3 text-body-main text-n-slate-11">{{ $t('ADAKI.CAPTAIN.LIMIT_HINT') }}</p>
          <label class="flex flex-col gap-1">
            <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.LIMIT_LABEL') }}</span>
            <input
              v-model="limit"
              type="number"
              min="0"
              :placeholder="$t('ADAKI.CAPTAIN.LIMIT_UNLIMITED')"
              class="form-input"
            />
          </label>
          <div class="mt-3 flex justify-end">
            <NextButton
              :label="$t('ADAKI.CAPTAIN.SAVE')"
              sm
              :is-loading="uiFlags.isUpdating"
              @click="save"
            />
          </div>
        </section>

        <section class="rounded-lg border border-n-weak p-4">
          <h3 class="mb-2 text-heading-3">{{ $t('ADAKI.CAPTAIN.USAGE_TITLE') }}</h3>
          <div v-if="settings" class="flex flex-col gap-2">
            <div class="flex justify-between gap-4">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_PERIOD') }}</span>
              <strong>{{ settings.current_period }}</strong>
            </div>
            <div class="flex justify-between gap-4">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_REQUESTS') }}</span>
              <strong>
                {{ settings.request_count }}
                <template v-if="settings.adaki_captain_monthly_limit">
                  / {{ settings.adaki_captain_monthly_limit }} ({{ usagePct }}%)
                </template>
              </strong>
            </div>
            <div class="flex justify-between gap-4">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_INPUT_TOKENS') }}</span>
              <strong>{{ settings.input_tokens }}</strong>
            </div>
            <div class="flex justify-between gap-4">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_OUTPUT_TOKENS') }}</span>
              <strong>{{ settings.output_tokens }}</strong>
            </div>
          </div>
        </section>

        <section class="rounded-lg border border-n-weak p-4">
          <div class="mb-4 flex items-start justify-between gap-3">
            <div>
              <h3 class="text-heading-3">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.HEADER') }}</h3>
              <p class="text-body-main text-n-slate-11">
                {{ $t('ADAKI.CAPTAIN.CREDENTIALS.DESCRIPTION') }}
              </p>
            </div>
            <NextButton
              :label="$t('ADAKI.CAPTAIN.CREDENTIALS.NEW')"
              sm
              @click="openCreateCredential"
            />
          </div>

          <BaseTable
            :headers="credentialHeaders"
            :items="credentials"
            :no-data-message="$t('ADAKI.CAPTAIN.CREDENTIALS.EMPTY')"
          >
            <template #row="{ items }">
              <BaseTableRow v-for="credential in items" :key="credential.id" :item="credential">
                <template #default>
                  <BaseTableCell>{{ credential.name }}</BaseTableCell>
                  <BaseTableCell>{{ providerLabel(credential.provider) }}</BaseTableCell>
                  <BaseTableCell>{{ rowModels(credential) }}</BaseTableCell>
                  <BaseTableCell>{{ credential.purpose }}</BaseTableCell>
                  <BaseTableCell>{{ authTypeLabel(credential.auth_type) }}</BaseTableCell>
                  <BaseTableCell>
                    <WootLabel
                      :label="statusLabel(credential.status)"
                      :color="statusColor(credential.status)"
                      compact
                    />
                  </BaseTableCell>
                  <BaseTableCell>{{ formatDate(credential.last_used_at) }}</BaseTableCell>
                  <BaseTableCell align="end">
                    <div class="flex justify-end gap-1">
                      <NextButton
                        :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.EDIT')"
                        sm
                        slate
                        @click="openEditCredential(credential)"
                      />
                      <NextButton
                        :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.VALIDATE')"
                        sm
                        :is-loading="credentialActionLoading.validate === credential.id"
                        @click="validateCredential(credential)"
                      />
                      <NextButton
                        :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.REVOKE')"
                        sm
                        ruby
                        :is-loading="credentialActionLoading.revoke === credential.id"
                        @click="revokeCredential(credential)"
                      />
                      <NextButton
                        :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.DELETE')"
                        sm
                        ruby
                        :is-loading="credentialActionLoading.destroy === credential.id"
                        @click="destroyCredential(credential)"
                      />
                    </div>
                  </BaseTableCell>
                </template>
              </BaseTableRow>
            </template>
          </BaseTable>
        </section>
      </div>

      <woot-modal v-model:show="showCredentialModal" :on-close="closeCredentialModal">
        <div class="w-[960px] max-w-[calc(100vw-2rem)] p-6">
          <div class="mb-5 flex items-start justify-between gap-4">
            <div class="space-y-1">
              <h2 class="text-heading-2">{{ credentialModalTitle }}</h2>
              <p class="text-sm text-n-slate-11">
                {{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.DESCRIPTION') }}
              </p>
            </div>
            <span
              class="shrink-0 rounded-full border border-n-weak px-3 py-1 text-xs font-medium text-n-slate-11"
            >
              {{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.BADGE') }}
            </span>
          </div>

          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.NAME') }}</span>
              <input
                v-model="credentialForm.name"
                class="form-input"
                type="text"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.NAME_PLACEHOLDER')"
              />
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.KEY') }}</span>
              <input
                v-model="credentialForm.key"
                class="form-input"
                type="text"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.KEY_PLACEHOLDER')"
              />
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.PROVIDER') }}</span>
              <select v-model="credentialForm.provider" class="form-input">
                <option disabled value="">
                  {{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.PROVIDER_PLACEHOLDER') }}
                </option>
                <option v-for="option in providerOptions" :key="option.value" :value="option.value">
                  {{ option.label }}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.MODEL') }}</span>
              <select v-model="credentialForm.metadata.model" class="form-input">
                <option disabled value="">
                  {{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.MODEL_PLACEHOLDER') }}
                </option>
                <option v-for="option in modelOptions" :key="option.value" :value="option.value">
                  {{ option.label }}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.PURPOSE') }}</span>
              <input
                v-model="credentialForm.purpose"
                class="form-input"
                type="text"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.PURPOSE_PLACEHOLDER')"
              />
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.AUTH_TYPE') }}</span>
              <select v-model="credentialForm.auth_type" class="form-input">
                <option v-for="option in authTypeOptions" :key="option.value" :value="option.value">
                  {{ option.label }}
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1 md:col-span-2">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_BASE') }}</span>
              <input
                v-model="credentialForm.metadata.api_base"
                class="form-input"
                type="text"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_BASE_PLACEHOLDER')"
              />
            </label>
          </div>

          <div class="mt-4 grid gap-4 rounded-2xl border border-n-weak p-4">
            <template v-if="credentialForm.auth_type === 'api_key'">
              <label class="flex flex-col gap-1">
                <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_KEY') }}</span>
                <input
                  v-model="credentialForm.secrets.api_key"
                  class="form-input"
                  type="password"
                  :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_KEY_PLACEHOLDER')"
                />
              </label>
            </template>

            <template v-else-if="credentialForm.auth_type === 'bearer'">
              <label class="flex flex-col gap-1">
                <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.TOKEN') }}</span>
                <input v-model="credentialForm.secrets.token" class="form-input" type="password" />
              </label>
            </template>

            <template v-else-if="credentialForm.auth_type === 'basic'">
              <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.USERNAME') }}</span>
                  <input v-model="credentialForm.secrets.username" class="form-input" type="text" />
                </label>
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.PASSWORD') }}</span>
                  <input v-model="credentialForm.secrets.password" class="form-input" type="password" />
                </label>
              </div>
            </template>

            <template v-else-if="credentialForm.auth_type === 'oauth2'">
              <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.ACCESS_TOKEN') }}</span>
                  <input v-model="credentialForm.secrets.access_token" class="form-input" type="password" />
                </label>
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.REFRESH_TOKEN') }}</span>
                  <input v-model="credentialForm.secrets.refresh_token" class="form-input" type="password" />
                </label>
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.CLIENT_ID') }}</span>
                  <input v-model="credentialForm.secrets.client_id" class="form-input" type="text" />
                </label>
                <label class="flex flex-col gap-1">
                  <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.CLIENT_SECRET') }}</span>
                  <input v-model="credentialForm.secrets.client_secret" class="form-input" type="password" />
                </label>
              </div>
            </template>

            <template v-else>
              <label class="flex flex-col gap-1">
                <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.CUSTOM_JSON') }}</span>
                <textarea
                  v-model="credentialForm.secrets.custom_json"
                  rows="6"
                  class="form-input font-mono"
                ></textarea>
              </label>
            </template>
          </div>

          <div class="mt-6 flex justify-end gap-2">
            <NextButton
              :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.CANCEL')"
              sm
              slate
              @click="closeCredentialModal"
            />
            <NextButton
              :label="isEditingCredential
                ? $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.UPDATE')
                : $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.SAVE')"
              sm
              :is-loading="uiFlags.isSavingCredential"
              @click="saveCredential"
            />
          </div>
        </div>
      </woot-modal>
    </template>
  </SettingsLayout>
</template>
