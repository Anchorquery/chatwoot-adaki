<script setup>
import {
  ref,
  reactive,
  computed,
  watch,
  onMounted,
  onBeforeUnmount,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import ConnectionCard from './components/ConnectionCard.vue';
import QrDialog from './components/QrDialog.vue';
import InstanceSettingsDialog from './components/InstanceSettingsDialog.vue';
import NewConnectionDialog from './components/NewConnectionDialog.vue';

const { t } = useI18n();
const router = useRouter();

// Con decenas de números, pedir todos los estados a la vez saturaría
// Evolution: se piden de pocos en pocos.
const MAX_PARALLEL_REQUESTS = 4;
const AUTO_REFRESH_MS = 60 * 1000;

const inboxes = useMapGetter('inboxes/getInboxes');
const inboxUiFlags = useMapGetter('inboxes/getUIFlags');

const searchQuery = ref('');
const connections = reactive({});
const restarting = reactive({});
const refreshingAll = ref(false);
const logoutTarget = ref(null);
const loggingOut = ref(false);

const qrDialog = ref(null);
const settingsDialog = ref(null);
const newDialog = ref(null);
const logoutDialog = ref(null);

let refreshTimer = null;

const evolutionEnabled = computed(
  () => window.chatwootConfig?.evolutionEnabled === true
);

const evolutionInboxes = computed(() =>
  (inboxes.value || [])
    .filter(
      inbox =>
        inbox.channel_type === 'Channel::Api' &&
        inbox.evolution_api_key_configured
    )
    .sort((a, b) => a.name.localeCompare(b.name))
);

const visibleInboxes = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return evolutionInboxes.value;
  return evolutionInboxes.value.filter(inbox => {
    const phone = connections[inbox.id]?.phone_number || '';
    return inbox.name.toLowerCase().includes(query) || phone.includes(query);
  });
});

const SUMMARY_KEYS = ['open', 'connecting', 'close', 'error'];

const summary = computed(() =>
  SUMMARY_KEYS.map(key => ({
    key,
    count: evolutionInboxes.value.filter(
      inbox => connections[inbox.id]?.status === key
    ).length,
  }))
);

const SUMMARY_STYLES = {
  open: 'text-n-teal-11',
  connecting: 'text-n-amber-11',
  close: 'text-n-ruby-11',
  error: 'text-n-slate-11',
};

const loadState = async inbox => {
  const previous = connections[inbox.id];
  connections[inbox.id] = previous
    ? { ...previous, refreshing: true }
    : { status: 'loading' };
  try {
    const { data } = await InboxesAPI.getEvolutionConnectionState(inbox.id);
    connections[inbox.id] = { ...data, status: data.state };
  } catch (error) {
    connections[inbox.id] = {
      status: 'error',
      error: error?.response?.data?.error || 'unreachable',
    };
  }
};

const runPool = async (items, worker) => {
  const queue = [...items];
  const runners = Array.from(
    { length: Math.min(MAX_PARALLEL_REQUESTS, queue.length) },
    async () => {
      while (queue.length) {
        // eslint-disable-next-line no-await-in-loop
        await worker(queue.shift());
      }
    }
  );
  await Promise.all(runners);
};

const refreshAll = async () => {
  if (refreshingAll.value) return;
  refreshingAll.value = true;
  try {
    await runPool(evolutionInboxes.value, loadState);
  } finally {
    refreshingAll.value = false;
  }
};

const onVisibilityChange = () => {
  if (document.visibilityState === 'visible') refreshAll();
};

const startAutoRefresh = () => {
  clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    if (document.visibilityState === 'visible') refreshAll();
  }, AUTO_REFRESH_MS);
};

// Las bandejas llegan del store; si se cargan después de montar la página (o
// se crea una nueva), se pide el estado de las que aún no lo tienen.
watch(
  () => evolutionInboxes.value.map(inbox => inbox.id),
  ids => {
    const pending = evolutionInboxes.value.filter(
      inbox => !connections[inbox.id]
    );
    if (pending.length) runPool(pending, loadState);
    Object.keys(connections).forEach(id => {
      if (!ids.includes(Number(id))) delete connections[id];
    });
  }
);

const openQr = inbox => qrDialog.value?.open(inbox);
const openSettings = inbox => settingsDialog.value?.open(inbox);
const openNew = () => newDialog.value?.open();

const openPrivacy = inbox =>
  router.push({
    name: 'settings_inbox_privacy_filter',
    params: { inboxId: inbox.id },
  });

const openInbox = inbox =>
  router.push({
    name: 'settings_inbox_show',
    params: { inboxId: inbox.id, tab: 'configuration' },
  });

const restart = async inbox => {
  restarting[inbox.id] = true;
  try {
    await InboxesAPI.restartEvolution(inbox.id);
    useAlert(t('WHATSAPP_CONNECTIONS.ALERTS.RESTARTED', { name: inbox.name }));
  } catch {
    useAlert(t('WHATSAPP_CONNECTIONS.ALERTS.RESTART_ERROR'));
  } finally {
    restarting[inbox.id] = false;
    loadState(inbox);
  }
};

const askLogout = inbox => {
  logoutTarget.value = inbox;
  logoutDialog.value?.open();
};

const confirmLogout = async () => {
  const inbox = logoutTarget.value;
  if (!inbox) return;
  loggingOut.value = true;
  try {
    await InboxesAPI.logoutEvolution(inbox.id);
    useAlert(t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT_SUCCESS'));
    logoutDialog.value?.close();
  } catch {
    useAlert(t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT_ERROR'));
  } finally {
    loggingOut.value = false;
    loadState(inbox);
  }
};

const onDialogClosed = inbox => {
  if (inbox) loadState(inbox);
};

onMounted(() => {
  refreshAll();
  startAutoRefresh();
  document.addEventListener('visibilitychange', onVisibilityChange);
});

onBeforeUnmount(() => {
  clearInterval(refreshTimer);
  document.removeEventListener('visibilitychange', onVisibilityChange);
});
</script>

<template>
  <SettingsLayout
    :is-loading="inboxUiFlags.isFetching && !evolutionInboxes.length"
    :loading-message="$t('WHATSAPP_CONNECTIONS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('WHATSAPP_CONNECTIONS.HEADER')"
        :description="$t('WHATSAPP_CONNECTIONS.DESCRIPTION')"
        :search-placeholder="
          evolutionInboxes.length ? $t('WHATSAPP_CONNECTIONS.SEARCH') : ''
        "
      >
        <template #actions>
          <NextButton
            type="button"
            variant="faded"
            color="slate"
            icon="i-lucide-refresh-cw"
            :label="$t('WHATSAPP_CONNECTIONS.REFRESH')"
            :is-loading="refreshingAll"
            :disabled="!evolutionInboxes.length"
            @click="refreshAll"
          />
          <NextButton
            v-tooltip.bottom="
              evolutionEnabled
                ? null
                : $t('WHATSAPP_CONNECTIONS.NOT_CONFIGURED')
            "
            type="button"
            icon="i-lucide-plus"
            :label="$t('WHATSAPP_CONNECTIONS.NEW_CONNECTION')"
            :disabled="!evolutionEnabled"
            @click="openNew"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div
        v-if="!evolutionInboxes.length"
        class="flex flex-col items-center gap-4 px-6 py-16 text-center rounded-2xl border border-dashed border-n-weak"
      >
        <span
          class="flex items-center justify-center size-14 rounded-2xl bg-n-teal-3 text-n-teal-11"
        >
          <span class="i-lucide-qr-code size-7" />
        </span>
        <div class="flex flex-col gap-1 max-w-md">
          <h2 class="text-base font-medium text-n-slate-12">
            {{ $t('WHATSAPP_CONNECTIONS.EMPTY.TITLE') }}
          </h2>
          <p class="text-sm text-n-slate-11">
            {{
              evolutionEnabled
                ? $t('WHATSAPP_CONNECTIONS.EMPTY.DESCRIPTION')
                : $t('WHATSAPP_CONNECTIONS.NOT_CONFIGURED')
            }}
          </p>
        </div>
        <NextButton
          v-if="evolutionEnabled"
          type="button"
          icon="i-lucide-plus"
          :label="$t('WHATSAPP_CONNECTIONS.NEW_CONNECTION')"
          @click="openNew"
        />
      </div>

      <div v-else class="flex flex-col gap-6">
        <dl class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            v-for="item in summary"
            :key="item.key"
            class="flex flex-col gap-1 p-4 rounded-xl border border-n-weak"
          >
            <dt class="text-xs text-n-slate-11">
              {{ $t(`WHATSAPP_CONNECTIONS.SUMMARY.${item.key.toUpperCase()}`) }}
            </dt>
            <dd
              class="text-2xl font-semibold tabular-nums"
              :class="item.count ? SUMMARY_STYLES[item.key] : 'text-n-slate-10'"
            >
              {{ item.count }}
            </dd>
          </div>
        </dl>

        <p
          v-if="!visibleInboxes.length"
          class="py-10 text-sm text-center text-n-slate-11"
        >
          {{ $t('WHATSAPP_CONNECTIONS.NO_RESULTS') }}
        </p>

        <div
          v-else
          class="grid grid-cols-1 lg:grid-cols-2 2xl:grid-cols-3 gap-4"
        >
          <ConnectionCard
            v-for="inbox in visibleInboxes"
            :key="inbox.id"
            :inbox="inbox"
            :connection="connections[inbox.id]"
            :restarting="restarting[inbox.id] === true"
            @qr="openQr"
            @settings="openSettings"
            @privacy="openPrivacy"
            @restart="restart"
            @logout="askLogout"
            @open="openInbox"
          />
        </div>
      </div>

      <QrDialog ref="qrDialog" @closed="onDialogClosed" />
      <InstanceSettingsDialog ref="settingsDialog" />
      <NewConnectionDialog
        ref="newDialog"
        @connected="loadState"
        @closed="onDialogClosed"
      />
      <Dialog
        ref="logoutDialog"
        type="alert"
        :title="
          $t('WHATSAPP_CONNECTIONS.LOGOUT_DIALOG.TITLE', {
            name: logoutTarget?.name,
          })
        "
        :description="$t('WHATSAPP_CONNECTIONS.LOGOUT_DIALOG.DESCRIPTION')"
        :confirm-button-label="$t('WHATSAPP_CONNECTIONS.ACTIONS.LOGOUT')"
        :is-loading="loggingOut"
        @confirm="confirmLogout"
      />
    </template>
  </SettingsLayout>
</template>
