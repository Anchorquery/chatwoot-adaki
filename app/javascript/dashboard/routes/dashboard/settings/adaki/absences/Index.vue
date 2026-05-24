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
import AbsenceForm from './AbsenceForm.vue';

export default {
  components: {
    SettingsLayout,
    BaseSettingsHeader,
    BaseTable,
    BaseTableRow,
    BaseTableCell,
    WootLabel,
    NextButton,
    AbsenceForm,
  },
  data() {
    return {
      showAddPopup: false,
      showDeletePopup: false,
      selected: null,
      editing: null,
    };
  },
  computed: {
    ...mapGetters({
      records: 'adakiAbsences/getAbsences',
      uiFlags: 'adakiAbsences/getUIFlags',
      agents: 'agents/getAgents',
    }),
    headers() {
      return [
        this.$t('ADAKI.ABSENCES.TABLE.USER'),
        this.$t('ADAKI.ABSENCES.TABLE.COVERAGE'),
        this.$t('ADAKI.ABSENCES.TABLE.START'),
        this.$t('ADAKI.ABSENCES.TABLE.END'),
        this.$t('ADAKI.ABSENCES.TABLE.STATUS'),
        this.$t('ADAKI.ABSENCES.TABLE.REASON'),
        this.$t('ADAKI.ABSENCES.TABLE.ACTIONS'),
      ];
    },
  },
  mounted() {
    this.$store.dispatch('adakiAbsences/get');
    this.$store.dispatch('agents/get');
  },
  methods: {
    userName(id) {
      const a = this.agents.find(x => x.id === id);
      return a ? a.name : `#${id}`;
    },
    statusColor(s) {
      return { active: 'teal', scheduled: 'amber', ended: 'slate', cancelled: 'ruby' }[s] || 'slate';
    },
    fmt(d) {
      return d ? new Date(d).toLocaleString() : '-';
    },
    openAdd() {
      this.editing = null;
      this.showAddPopup = true;
    },
    openEdit(item) {
      this.editing = item;
      this.showAddPopup = true;
    },
    closeForm() {
      this.showAddPopup = false;
      this.editing = null;
    },
    openDelete(item) {
      this.selected = item;
      this.showDeletePopup = true;
    },
    confirmDelete() {
      this.$store
        .dispatch('adakiAbsences/delete', this.selected.id)
        .then(() => useAlert(this.$t('ADAKI.ABSENCES.ALERTS.CANCELLED')))
        .catch(e => useAlert(e.message || this.$t('ADAKI.ABSENCES.ALERTS.ERROR')))
        .finally(() => {
          this.showDeletePopup = false;
          this.selected = null;
        });
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching" :loading-message="$t('ADAKI.ABSENCES.LOADING')">
    <template #header>
      <BaseSettingsHeader
        :title="$t('ADAKI.ABSENCES.HEADER')"
        :description="$t('ADAKI.ABSENCES.DESCRIPTION')"
        :show-back-button="false"
      >
        <template #actions>
          <NextButton :label="$t('ADAKI.ABSENCES.ADD_ACTION')" size="sm" @click="openAdd" />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <BaseTable
        :headers="headers"
        :items="records"
        :no-data-message="$t('ADAKI.ABSENCES.EMPTY')"
      >
        <template #row="{ items }">
          <BaseTableRow v-for="a in items" :key="a.id" :item="a">
            <template #default>
              <BaseTableCell>{{ userName(a.user_id) }}</BaseTableCell>
              <BaseTableCell>{{ a.coverage_user_id ? userName(a.coverage_user_id) : '—' }}</BaseTableCell>
              <BaseTableCell>{{ fmt(a.start_at) }}</BaseTableCell>
              <BaseTableCell>{{ fmt(a.end_at) }}</BaseTableCell>
              <BaseTableCell>
                <WootLabel :label="a.status" :color="statusColor(a.status)" compact />
              </BaseTableCell>
              <BaseTableCell>{{ a.reason || '—' }}</BaseTableCell>
              <BaseTableCell align="end">
                <div class="flex justify-end gap-1">
                  <NextButton icon="i-lucide-pencil" slate sm @click="openEdit(a)" />
                  <NextButton
                    v-if="a.status !== 'cancelled'"
                    icon="i-woot-bin"
                    slate
                    sm
                    @click="openDelete(a)"
                  />
                </div>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>

      <woot-modal v-model:show="showAddPopup" :on-close="closeForm">
        <AbsenceForm :absence="editing" :agents="agents" @close="closeForm" />
      </woot-modal>

      <woot-delete-modal
        v-model:show="showDeletePopup"
        :on-close="() => (showDeletePopup = false)"
        :on-confirm="confirmDelete"
        :title="$t('ADAKI.ABSENCES.DELETE.TITLE')"
        :message="$t('ADAKI.ABSENCES.DELETE.MESSAGE')"
        :confirm-text="$t('ADAKI.ABSENCES.DELETE.CONFIRM')"
        :reject-text="$t('ADAKI.ABSENCES.DELETE.REJECT')"
      />
    </template>
  </SettingsLayout>
</template>
