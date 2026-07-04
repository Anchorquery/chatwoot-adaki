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
      showActionModal: false,
      actionType: null,
      note: '',
      selected: null,
    };
  },
  computed: {
    ...mapGetters({
      campaigns: 'campaigns/getAllCampaigns',
      uiFlags: 'adakiApprovals/getUIFlags',
      currentUser: 'getCurrentUser',
    }),
    pendingCampaigns() {
      return this.campaigns.filter(
        c => c.requires_approval && c.approval_status === 'pending'
      );
    },
    headers() {
      return [
        this.$t('ADAKI.APPROVALS.TABLE.CAMPAIGN'),
        this.$t('ADAKI.APPROVALS.TABLE.INBOX'),
        this.$t('ADAKI.APPROVALS.TABLE.REQUESTER'),
        this.$t('ADAKI.APPROVALS.TABLE.STATUS'),
        this.$t('ADAKI.APPROVALS.TABLE.ACTIONS'),
      ];
    },
  },
  mounted() {
    this.$store.dispatch('campaigns/get');
  },
  methods: {
    statusColor(s) {
      return (
        { pending: 'amber', approved: 'teal', rejected: 'ruby' }[s] || 'slate'
      );
    },
    isOwnRequest(campaign) {
      return campaign.sender?.id === this.currentUser.id;
    },
    open(campaign, type) {
      this.selected = campaign;
      this.actionType = type;
      this.note = '';
      this.showActionModal = true;
    },
    async submit() {
      const action =
        this.actionType === 'approve'
          ? 'adakiApprovals/approve'
          : 'adakiApprovals/reject';
      try {
        await this.$store.dispatch(action, {
          campaignId: this.selected.display_id || this.selected.id,
          note: this.note,
        });
        useAlert(
          this.actionType === 'approve'
            ? this.$t('ADAKI.APPROVALS.ALERTS.APPROVED')
            : this.$t('ADAKI.APPROVALS.ALERTS.REJECTED')
        );
        await this.$store.dispatch('campaigns/get');
      } catch (e) {
        useAlert(e.message || this.$t('ADAKI.APPROVALS.ALERTS.ERROR'));
      } finally {
        this.showActionModal = false;
      }
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="false" loading-message="">
    <template #header>
      <BaseSettingsHeader
        :title="$t('ADAKI.APPROVALS.HEADER')"
        :description="$t('ADAKI.APPROVALS.DESCRIPTION')"
        :show-back-button="false"
      />
    </template>
    <template #body>
      <BaseTable
        :headers="headers"
        :items="pendingCampaigns"
        :no-data-message="$t('ADAKI.APPROVALS.EMPTY')"
      >
        <template #row="{ items }">
          <BaseTableRow v-for="c in items" :key="c.id" :item="c">
            <template #default>
              <BaseTableCell>{{ c.title }}</BaseTableCell>
              <BaseTableCell>{{ c.inbox?.name || '—' }}</BaseTableCell>
              <BaseTableCell>
                {{ c.sender?.name || c.sender?.email || '—' }}
              </BaseTableCell>
              <BaseTableCell>
                <WootLabel
                  :label="c.approval_status"
                  :color="statusColor(c.approval_status)"
                  compact
                />
              </BaseTableCell>
              <BaseTableCell align="end">
                <div
                  class="flex justify-end gap-1"
                  :title="
                    isOwnRequest(c)
                      ? $t('ADAKI.APPROVALS.CANNOT_SELF_APPROVE')
                      : undefined
                  "
                >
                  <NextButton
                    :label="$t('ADAKI.APPROVALS.APPROVE')"
                    sm
                    :disabled="isOwnRequest(c)"
                    @click="open(c, 'approve')"
                  />
                  <NextButton
                    :label="$t('ADAKI.APPROVALS.REJECT')"
                    sm
                    ruby
                    :disabled="isOwnRequest(c)"
                    @click="open(c, 'reject')"
                  />
                </div>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>

      <woot-modal
        v-model:show="showActionModal"
        :on-close="() => (showActionModal = false)"
      >
        <div class="p-6 w-[420px]">
          <h2 class="text-heading-2 mb-3">
            {{
              actionType === 'approve'
                ? $t('ADAKI.APPROVALS.MODAL.TITLE_APPROVE')
                : $t('ADAKI.APPROVALS.MODAL.TITLE_REJECT')
            }}
          </h2>
          <p class="text-body-main mb-3">{{ selected?.title }}</p>
          <label class="flex flex-col gap-1 mb-3">
            <span class="text-body-main">{{
              $t('ADAKI.APPROVALS.MODAL.NOTE_LABEL')
            }}</span>
            <textarea v-model="note" rows="3" class="form-input" />
          </label>
          <div class="flex justify-end gap-2">
            <NextButton
              :label="$t('ADAKI.APPROVALS.MODAL.CANCEL')"
              slate
              sm
              @click="showActionModal = false"
            />
            <NextButton
              :label="
                actionType === 'approve'
                  ? $t('ADAKI.APPROVALS.APPROVE')
                  : $t('ADAKI.APPROVALS.REJECT')
              "
              sm
              :ruby="actionType === 'reject'"
              :is-loading="uiFlags.isApproving || uiFlags.isRejecting"
              @click="submit"
            />
          </div>
        </div>
      </woot-modal>
    </template>
  </SettingsLayout>
</template>
