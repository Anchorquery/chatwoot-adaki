<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../../SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: { SettingsLayout, BaseSettingsHeader, NextButton },
  data() {
    return {
      limit: '',
    };
  },
  computed: {
    ...mapGetters({
      settings: 'adakiCaptainSettings/getSettings',
      uiFlags: 'adakiCaptainSettings/getUIFlags',
    }),
    usagePct() {
      if (!this.settings?.adaki_captain_monthly_limit) return null;
      return Math.round((this.settings.request_count / this.settings.adaki_captain_monthly_limit) * 100);
    },
  },
  watch: {
    settings(val) {
      if (val) this.limit = val.adaki_captain_monthly_limit ?? '';
    },
  },
  mounted() {
    this.$store.dispatch('adakiCaptainSettings/fetch');
  },
  methods: {
    async save() {
      try {
        await this.$store.dispatch('adakiCaptainSettings/update', {
          adaki_captain_monthly_limit: this.limit === '' ? null : Number(this.limit),
        });
        useAlert(this.$t('ADAKI.CAPTAIN.ALERTS.SAVED'));
      } catch (e) {
        useAlert(e.message || this.$t('ADAKI.CAPTAIN.ALERTS.ERROR'));
      }
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
      <div class="max-w-xl flex flex-col gap-6">
        <section class="border border-n-weak rounded-lg p-4">
          <h3 class="text-heading-3 mb-2">{{ $t('ADAKI.CAPTAIN.LIMIT_TITLE') }}</h3>
          <p class="text-body-main text-n-slate-11 mb-3">{{ $t('ADAKI.CAPTAIN.LIMIT_HINT') }}</p>
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
          <div class="flex justify-end mt-3">
            <NextButton
              :label="$t('ADAKI.CAPTAIN.SAVE')"
              sm
              :is-loading="uiFlags.isUpdating"
              @click="save"
            />
          </div>
        </section>

        <section class="border border-n-weak rounded-lg p-4">
          <h3 class="text-heading-3 mb-2">{{ $t('ADAKI.CAPTAIN.USAGE_TITLE') }}</h3>
          <div v-if="settings" class="flex flex-col gap-2">
            <div class="flex justify-between">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_PERIOD') }}</span>
              <strong>{{ settings.current_period }}</strong>
            </div>
            <div class="flex justify-between">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_REQUESTS') }}</span>
              <strong>
                {{ settings.request_count }}
                <template v-if="settings.adaki_captain_monthly_limit">
                  / {{ settings.adaki_captain_monthly_limit }} ({{ usagePct }}%)
                </template>
              </strong>
            </div>
            <div class="flex justify-between">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_INPUT_TOKENS') }}</span>
              <strong>{{ settings.input_tokens }}</strong>
            </div>
            <div class="flex justify-between">
              <span>{{ $t('ADAKI.CAPTAIN.USAGE_OUTPUT_TOKENS') }}</span>
              <strong>{{ settings.output_tokens }}</strong>
            </div>
          </div>
        </section>
      </div>
    </template>
  </SettingsLayout>
</template>
