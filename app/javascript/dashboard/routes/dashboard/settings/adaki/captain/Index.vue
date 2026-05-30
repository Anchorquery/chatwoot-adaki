<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../../SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ProviderCard from 'dashboard/components-next/captain/pageComponents/providers/ProviderCard.vue';
import PlatformCredentialModelsAPI from '../../../../../api/platform/credentialModels';

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
    NextButton,
    ProviderCard,
  },
  data() {
    return {
      limit: '',
      showCredentialModal: false,
      editingCredentialId: null,
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
  },
  mounted() {
    this.$store.dispatch('adakiCaptainSettings/fetch');
  },
  methods: {
    defaultProvider() {
      return this.providerOptions[0]?.value || 'openai';
    },
    providerLabel(provider) {
      return this.providerOptions.find(option => option.value === provider)?.label || provider || '-';
    },
    async save() {
      try {
        const value = this.limit === '' || this.limit === null ? null : Number(this.limit);
        await this.$store.dispatch('adakiCaptainSettings/update', {
          adaki_captain_monthly_limit: value,
        });
        useAlert(this.$t('ADAKI.CAPTAIN.ALERTS.SAVED'));
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.ALERTS.ERROR'));
      }
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
      const provider = credential.provider || this.defaultProvider();

      this.credentialForm = {
        provider,
        purpose: credential.purpose || 'ai_provider',
        key: credential.key || '',
        name: credential.name || '',
        auth_type: 'api_key',
        metadata: {
          api_base: credential.metadata?.api_base || '',
          model: credential.metadata?.model || '',
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
      this.resetCredentialForm(this.defaultProvider());
    },
    secretPayload() {
      const apiKey = this.credentialForm.secrets.api_key.trim();
      return apiKey ? { api_key: apiKey } : null;
    },
    async saveCredential() {
      try {
        const payload = this.secretPayload();
        if (!this.isEditingCredential && !payload) {
          useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.SECRET_REQUIRED'));
          return;
        }

        const credential = {
          provider: this.credentialForm.provider,
          purpose: 'ai_provider',
          key: this.credentialForm.key || undefined,
          name: this.credentialForm.name,
          auth_type: 'api_key',
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
    openProviderModels(credential) {
      this.$router.push({
        name: 'adaki_provider_models',
        params: {
          accountId: this.$route.params.accountId,
          credentialId: credential.id,
        },
      });
    },
    async syncProviderModels(credential) {
      try {
        const { data } = await PlatformCredentialModelsAPI.sync(credential.id);
        useAlert(this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.MODELS_SYNCED', { count: data.imported }));
        this.openProviderModels(credential);
      } catch (error) {
        const msg = error.response?.data?.error || error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR');
        useAlert(msg);
      }
    },
    async toggleProviderEnabled(credential, enabled) {
      try {
        if (enabled) {
          await this.$store.dispatch('adakiCaptainSettings/validateCredential', credential.id);
        } else {
          await this.$store.dispatch('adakiCaptainSettings/revokeCredential', credential.id);
        }
        useAlert(this.$t(enabled ? 'ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ENABLED' : 'ADAKI.CAPTAIN.CREDENTIALS.ALERTS.REVOKED'));
      } catch (error) {
        useAlert(error.message || this.$t('ADAKI.CAPTAIN.CREDENTIALS.ALERTS.ERROR'));
      }
    },
    handleProviderAction({ action }, credential) {
      switch (action) {
        case 'sync_models': this.syncProviderModels(credential); break;
        case 'configure_models': this.openProviderModels(credential); break;
        case 'edit': this.openEditCredential(credential); break;
        case 'validate': this.validateCredential(credential); break;
        case 'delete': this.destroyCredential(credential); break;
        default: break;
      }
    },
    handleProviderToggle({ enabled }, credential) {
      this.toggleProviderEnabled(credential, enabled);
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

          <div
            v-if="!credentials.length"
            class="rounded-lg border border-dashed border-n-weak p-6 text-center text-sm text-n-slate-11"
          >
            {{ $t('ADAKI.CAPTAIN.CREDENTIALS.EMPTY') }}
          </div>

          <div v-else class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <ProviderCard
              v-for="credential in credentials"
              :key="credential.id"
              :id="credential.id"
              :name="credential.name"
              :provider="credential.provider"
              :provider-label="providerLabel(credential.provider)"
              :status="credential.status"
              @action="handleProviderAction($event, credential)"
              @toggle="handleProviderToggle($event, credential)"
            />
          </div>
        </section>
      </div>

      <woot-modal
        v-model:show="showCredentialModal"
        size="medium"
        :on-close="closeCredentialModal"
      >
        <form class="w-full p-6" autocomplete="off" @submit.prevent="saveCredential">
          <div
            aria-hidden="true"
            style="position: absolute; left: -9999px; top: -9999px; width: 1px; height: 1px; overflow: hidden; opacity: 0; pointer-events: none;"
          >
            <input
              type="text"
              name="fake-username"
              autocomplete="username"
              tabindex="-1"
            />
            <input
              type="password"
              name="fake-password"
              autocomplete="new-password"
              tabindex="-1"
            />
          </div>
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

          <div class="grid grid-cols-1 gap-4">
            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.NAME') }}</span>
              <input
                v-model="credentialForm.name"
                class="form-input"
                type="text"
                name="credential_name"
                autocomplete="off"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.NAME_PLACEHOLDER')"
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
              <span class="text-body-main">
                {{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_BASE') }}
                <span class="text-n-slate-10">({{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.OPTIONAL') }})</span>
              </span>
              <input
                v-model="credentialForm.metadata.api_base"
                class="form-input"
                type="url"
                name="credential_api_base_url"
                autocomplete="off"
                inputmode="url"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_BASE_PLACEHOLDER')"
              />
            </label>

            <label class="flex flex-col gap-1">
              <span class="text-body-main">{{ $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_KEY') }}</span>
              <input
                v-model="credentialForm.secrets.api_key"
                class="form-input"
                type="password"
                name="credential_api_key"
                autocomplete="new-password"
                :placeholder="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.API_KEY_PLACEHOLDER')"
              />
            </label>
          </div>

          <div class="mt-6 flex justify-end gap-2">
            <NextButton
              type="button"
              :label="$t('ADAKI.CAPTAIN.CREDENTIALS.FORM.CANCEL')"
              sm
              slate
              @click="closeCredentialModal"
            />
            <NextButton
              type="submit"
              :label="isEditingCredential
                ? $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.UPDATE')
                : $t('ADAKI.CAPTAIN.CREDENTIALS.FORM.SAVE')"
              sm
              :is-loading="uiFlags.isSavingCredential"
              @click="saveCredential"
            />
          </div>
        </form>
      </woot-modal>
    </template>
  </SettingsLayout>
</template>
