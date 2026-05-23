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
      loading: {},
      showUnlockModal: false,
      unlockReason: '',
      selectedChannel: null,
    };
  },
  computed: {
    ...mapGetters({
      channels: 'adakiTier/getChannels',
      uiFlags: 'adakiTier/getUIFlags',
    }),
    headers() {
      return ['Número', 'Proveedor', 'Tier', 'Quality', 'Límite diario', 'Última lectura', 'Estado', 'Acciones'];
    },
  },
  mounted() {
    this.$store.dispatch('adakiTier/get');
  },
  methods: {
    qualityColor(q) {
      return { GREEN: 'teal', YELLOW: 'amber', RED: 'ruby' }[q] || 'slate';
    },
    fmt(d) {
      return d ? new Date(d).toLocaleString() : 'nunca';
    },
    refresh(channel) {
      this.loading[channel.id] = true;
      this.$store
        .dispatch('adakiTier/refreshTier', channel.id)
        .then(() => useAlert('Tier actualizado'))
        .catch(e => useAlert(e.message || 'Error'))
        .finally(() => {
          this.loading[channel.id] = false;
        });
    },
    openUnlock(channel) {
      this.selectedChannel = channel;
      this.unlockReason = '';
      this.showUnlockModal = true;
    },
    confirmUnlock() {
      this.loading[this.selectedChannel.id] = true;
      this.$store
        .dispatch('adakiTier/unlockTier', {
          channelId: this.selectedChannel.id,
          reason: this.unlockReason,
        })
        .then(() => useAlert('Canal desbloqueado'))
        .catch(e => useAlert(e.message || 'Error'))
        .finally(() => {
          this.loading[this.selectedChannel.id] = false;
          this.showUnlockModal = false;
          this.selectedChannel = null;
        });
    },
  },
};
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching" loading-message="Cargando canales">
    <template #header>
      <BaseSettingsHeader
        title="Tier WhatsApp y warming"
        description="Estado de límites de envío por canal según Meta. Lock automático al 95% y RED quality."
        :show-back-button="false"
      />
    </template>
    <template #body>
      <BaseTable
        :headers="headers"
        :items="channels"
        no-data-message="Sin canales WhatsApp Cloud configurados"
      >
        <template #row="{ items }">
          <BaseTableRow v-for="c in items" :key="c.id" :item="c">
            <template #default>
              <BaseTableCell>{{ c.phone_number }}</BaseTableCell>
              <BaseTableCell>{{ c.provider }}</BaseTableCell>
              <BaseTableCell>{{ c.messaging_tier || '—' }}</BaseTableCell>
              <BaseTableCell>
                <WootLabel
                  v-if="c.quality_rating"
                  :label="c.quality_rating"
                  :color="qualityColor(c.quality_rating)"
                  compact
                />
                <span v-else>—</span>
              </BaseTableCell>
              <BaseTableCell>{{ c.daily_conversation_limit || '—' }}</BaseTableCell>
              <BaseTableCell>{{ fmt(c.tier_checked_at) }}</BaseTableCell>
              <BaseTableCell>
                <WootLabel
                  :label="c.tier_locked ? 'BLOQUEADO' : 'OK'"
                  :color="c.tier_locked ? 'ruby' : 'teal'"
                  compact
                />
              </BaseTableCell>
              <BaseTableCell align="end">
                <div class="flex justify-end gap-1">
                  <NextButton
                    label="Refrescar"
                    sm
                    slate
                    :is-loading="loading[c.id]"
                    @click="refresh(c)"
                  />
                  <NextButton
                    v-if="c.tier_locked"
                    label="Desbloquear"
                    sm
                    ruby
                    @click="openUnlock(c)"
                  />
                </div>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>

      <woot-modal v-model:show="showUnlockModal" :on-close="() => (showUnlockModal = false)">
        <div class="p-6 w-[420px]">
          <h2 class="text-heading-2 mb-2">Desbloquear canal</h2>
          <p class="text-body-main mb-3">
            Canal {{ selectedChannel?.phone_number }}. Motivo del bloqueo:
            <strong>{{ selectedChannel?.tier_lock_reason }}</strong>
          </p>
          <label class="flex flex-col gap-1 mb-3">
            <span class="text-body-main">Justificación (queda en audit log)</span>
            <textarea v-model="unlockReason" rows="3" class="form-input" required />
          </label>
          <div class="flex justify-end gap-2">
            <NextButton label="Cancelar" slate sm @click="showUnlockModal = false" />
            <NextButton label="Desbloquear" ruby sm @click="confirmUnlock" />
          </div>
        </div>
      </woot-modal>
    </template>
  </SettingsLayout>
</template>
