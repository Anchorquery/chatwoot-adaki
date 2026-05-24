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
      actionFilter: '',
      auditableTypeFilter: '',
    };
  },
  computed: {
    ...mapGetters({
      records: 'adakiAudit/getEntries',
      verifyResult: 'adakiAudit/getVerifyResult',
      uiFlags: 'adakiAudit/getUIFlags',
    }),
    headers() {
      return [
        this.$t('ADAKI.AUDIT.TABLE.WHEN'),
        this.$t('ADAKI.AUDIT.TABLE.USER'),
        this.$t('ADAKI.AUDIT.TABLE.ACTION'),
        this.$t('ADAKI.AUDIT.TABLE.OBJECT'),
        this.$t('ADAKI.AUDIT.TABLE.PAYLOAD'),
        this.$t('ADAKI.AUDIT.TABLE.HASH'),
      ];
    },
    filtered() {
      return this.records.filter(r => {
        if (this.actionFilter && !r.action.includes(this.actionFilter)) return false;
        if (this.auditableTypeFilter && r.auditable_type !== this.auditableTypeFilter) return false;
        return true;
      });
    },
    auditableTypes() {
      const s = new Set();
      this.records.forEach(r => r.auditable_type && s.add(r.auditable_type));
      return Array.from(s);
    },
  },
  mounted() {
    this.$store.dispatch('adakiAudit/get');
  },
  methods: {
    fmt(d) {
      return d ? new Date(d).toLocaleString() : '-';
    },
    short(h) {
      return h ? `${h.slice(0, 12)}…` : '';
    },
    async verify() {
      const result = await this.$store.dispatch('adakiAudit/verify');
      if (result?.valid) {
        useAlert(this.$t('ADAKI.AUDIT.VERIFY_OK'));
      } else {
        useAlert(`${this.$t('ADAKI.AUDIT.VERIFY_FAIL')}: ${result?.error || ''}`);
      }
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching" :loading-message="$t('ADAKI.AUDIT.HEADER')">
    <template #header>
      <BaseSettingsHeader
        :title="$t('ADAKI.AUDIT.HEADER')"
        :description="$t('ADAKI.AUDIT.DESCRIPTION')"
        :show-back-button="false"
      >
        <template #actions>
          <NextButton
            :label="uiFlags.isVerifying ? $t('ADAKI.AUDIT.VERIFYING') : $t('ADAKI.AUDIT.VERIFY')"
            sm
            :is-loading="uiFlags.isVerifying"
            @click="verify"
          />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <div
        v-if="verifyResult"
        class="mb-4 p-3 rounded border"
        :class="verifyResult.valid ? 'border-n-teal-7 bg-n-teal-2' : 'border-n-ruby-7 bg-n-ruby-2'"
      >
        <strong>{{ verifyResult.valid ? $t('ADAKI.AUDIT.VERIFY_OK') : $t('ADAKI.AUDIT.VERIFY_FAIL') }}</strong>
        <div v-if="!verifyResult.valid" class="text-body-main mt-1">{{ verifyResult.error }}</div>
      </div>

      <div class="flex gap-3 mb-4">
        <input
          v-model="actionFilter"
          :placeholder="$t('ADAKI.AUDIT.FILTER_ACTION')"
          class="form-input flex-1"
        />
        <select v-model="auditableTypeFilter" class="form-input">
          <option value="">{{ $t('ADAKI.AUDIT.FILTER_TYPE_ALL') }}</option>
          <option v-for="t in auditableTypes" :key="t" :value="t">{{ t }}</option>
        </select>
      </div>

      <BaseTable :headers="headers" :items="filtered" :no-data-message="$t('ADAKI.AUDIT.EMPTY')">
        <template #row="{ items }">
          <BaseTableRow v-for="e in items" :key="e.id" :item="e">
            <template #default>
              <BaseTableCell>{{ fmt(e.recorded_at) }}</BaseTableCell>
              <BaseTableCell>{{ e.user_email || e.user_id || 'sistema' }}</BaseTableCell>
              <BaseTableCell>
                <WootLabel :label="e.action" color="slate" compact />
              </BaseTableCell>
              <BaseTableCell>{{ e.auditable_type }} #{{ e.auditable_id }}</BaseTableCell>
              <BaseTableCell>
                <code class="text-xs">{{ JSON.stringify(e.payload).slice(0, 60) }}</code>
              </BaseTableCell>
              <BaseTableCell>
                <code v-tooltip="e.hash_chain" class="text-xs">{{ short(e.hash_chain) }}</code>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>
    </template>
  </SettingsLayout>
</template>
