<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  inboxId: {
    type: [String, Number],
    required: true,
  },
  // En el alta, la sesión recién creada ya espera el escaneo: se pide el QR
  // sin obligar a un clic más.
  autoConnect: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['connected', 'disconnected']);

const { t } = useI18n();

// Mientras el QR está en pantalla se mira el estado cada pocos segundos para
// detectar el escaneo casi al instante. Baileys rota el QR cada ~20s, así que
// también se pide uno nuevo con esa cadencia.
const STATE_POLL_MS = 3000;
const QR_REFRESH_MS = 20000;
const QR_RETRY_MS = 2500;
// Pasado este tiempo sin escaneo se deja de sondear: una instancia que se
// queda generando QR sin que nadie mire es justo la que se atasca en
// 'connecting' y consume memoria en Evolution.
const QR_TIMEOUT_MS = 3 * 60 * 1000;

// loading | open | connecting | close | expired | error
const status = ref('loading');
const errorCode = ref('');
const qrCode = ref(null);
const pairingCode = ref(null);
const profile = ref({});
const requestingQr = ref(false);
const loggingOut = ref(false);
const confirmingLogout = ref(false);

let statePollTimer = null;
let qrRefreshTimer = null;
let qrTimeoutTimer = null;
let pollingState = false;
let unmounted = false;

const STATUS_STYLES = {
  open: { dot: 'bg-n-teal-9', ring: 'bg-n-teal-9/40', text: 'text-n-teal-11' },
  connecting: {
    dot: 'bg-n-amber-9',
    ring: 'bg-n-amber-9/40',
    text: 'text-n-amber-11',
  },
  close: { dot: 'bg-n-ruby-9', ring: '', text: 'text-n-ruby-11' },
  expired: { dot: 'bg-n-ruby-9', ring: '', text: 'text-n-ruby-11' },
  error: { dot: 'bg-n-slate-9', ring: '', text: 'text-n-slate-11' },
};

const statusStyle = computed(
  () => STATUS_STYLES[status.value] || STATUS_STYLES.error
);

const statusLabel = computed(() => {
  if (status.value === 'error') {
    const key =
      errorCode.value === 'not_configured' ? 'NOT_CONFIGURED' : 'UNREACHABLE';
    return t(`INBOX_MGMT.EVOLUTION_CONNECTION.ERRORS.${key}`);
  }
  return t(
    `INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.${status.value.toUpperCase()}`
  );
});

const showQr = computed(() => status.value === 'connecting');
const isConnected = computed(() => status.value === 'open');
const canRequestQr = computed(() =>
  ['close', 'expired', 'error'].includes(status.value)
);

const formattedPhone = computed(() => {
  const number = profile.value.phone_number;
  return number ? `+${number}` : '';
});

const clearTimers = () => {
  clearInterval(statePollTimer);
  clearTimeout(qrRefreshTimer);
  clearTimeout(qrTimeoutTimer);
  statePollTimer = null;
  qrRefreshTimer = null;
  qrTimeoutTimer = null;
};

const handleError = error => {
  clearTimers();
  qrCode.value = null;
  errorCode.value = error?.response?.data?.error || 'unreachable';
  status.value = 'error';
};

const markConnected = data => {
  const wasConnected = status.value === 'open';
  clearTimers();
  qrCode.value = null;
  pairingCode.value = null;
  profile.value = {
    phone_number: data.phone_number,
    profile_name: data.profile_name,
    profile_picture_url: data.profile_picture_url,
  };
  status.value = 'open';
  if (!wasConnected) emit('connected');
};

const expireQr = () => {
  clearTimers();
  qrCode.value = null;
  status.value = 'expired';
};

// Declarada antes que requestQr porque se llaman mutuamente vía timers.
let requestQr = null;

const scheduleQrRefresh = delay => {
  clearTimeout(qrRefreshTimer);
  qrRefreshTimer = setTimeout(() => requestQr({ silent: true }), delay);
};

const pollState = async () => {
  if (pollingState || unmounted) return;
  pollingState = true;
  try {
    const { data } = await InboxesAPI.getEvolutionConnectionState(
      props.inboxId
    );
    if (unmounted) return;
    if (data.state === 'open') {
      markConnected(data);
      useAlert(t('INBOX_MGMT.EVOLUTION_CONNECTION.CONNECTED_ALERT'));
    } else if (data.state === 'close' && showQr.value) {
      // Evolution dejó de emitir QR (límite de intentos): no se reintenta
      // solo, el admin decide si genera otro.
      expireQr();
    }
  } catch {
    // Un fallo puntual del sondeo no tumba el QR: el siguiente tick reintenta.
  } finally {
    pollingState = false;
  }
};

const startPolling = () => {
  if (!statePollTimer) {
    statePollTimer = setInterval(pollState, STATE_POLL_MS);
  }
  if (!qrTimeoutTimer) {
    qrTimeoutTimer = setTimeout(expireQr, QR_TIMEOUT_MS);
  }
};

requestQr = async ({ silent = false } = {}) => {
  if (unmounted) return;
  if (!silent) requestingQr.value = true;
  try {
    const { data } = await InboxesAPI.connectEvolution(props.inboxId);
    if (unmounted) return;
    // Un refresco automático que vuelve después de que el QR caducara (o de
    // que el teléfono se vinculara) no debe reactivar el sondeo.
    if (silent && status.value !== 'connecting') return;
    if (data.state === 'open') {
      markConnected(data);
      return;
    }
    status.value = 'connecting';
    errorCode.value = '';
    qrCode.value = data.qr_code || qrCode.value;
    pairingCode.value = data.pairing_code || null;
    startPolling();
    // Recién arrancada, Evolution tarda un par de segundos en tener el primer
    // QR: si aún no llegó, se vuelve a pedir enseguida.
    scheduleQrRefresh(data.qr_code ? QR_REFRESH_MS : QR_RETRY_MS);
  } catch (error) {
    if (unmounted || (silent && status.value !== 'connecting')) return;
    if (!silent || !qrCode.value) handleError(error);
    else scheduleQrRefresh(QR_RETRY_MS);
  } finally {
    requestingQr.value = false;
  }
};

const startConnection = () => {
  clearTimers();
  requestQr();
};

const loadState = async () => {
  status.value = 'loading';
  try {
    const { data } = await InboxesAPI.getEvolutionConnectionState(
      props.inboxId
    );
    if (unmounted) return;
    if (data.state === 'open') {
      markConnected(data);
    } else if (data.state === 'connecting' || props.autoConnect) {
      // 'connecting' = ya está esperando un escaneo: se muestra su QR.
      await requestQr();
    } else {
      status.value = 'close';
    }
  } catch (error) {
    handleError(error);
  }
};

const logout = async () => {
  loggingOut.value = true;
  try {
    await InboxesAPI.logoutEvolution(props.inboxId);
    profile.value = {};
    status.value = 'close';
    emit('disconnected');
    useAlert(t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT_SUCCESS'));
  } catch {
    useAlert(t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT_ERROR'));
  } finally {
    loggingOut.value = false;
    confirmingLogout.value = false;
  }
};

onMounted(loadState);

onBeforeUnmount(() => {
  unmounted = true;
  clearTimers();
});
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex items-center gap-3">
      <Spinner v-if="status === 'loading'" class="size-4" />
      <span v-else class="relative flex size-3 shrink-0">
        <span
          v-if="statusStyle.ring && status !== 'expired'"
          class="absolute inline-flex size-full rounded-full animate-ping"
          :class="statusStyle.ring"
        />
        <span
          class="relative inline-flex size-3 rounded-full"
          :class="statusStyle.dot"
        />
      </span>
      <span
        class="text-sm font-medium"
        :class="status === 'loading' ? 'text-n-slate-11' : statusStyle.text"
      >
        {{
          status === 'loading'
            ? $t('INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.LOADING')
            : statusLabel
        }}
      </span>
    </div>

    <div
      v-if="isConnected"
      class="flex items-center gap-3 p-3 rounded-xl border border-n-weak bg-n-alpha-1"
    >
      <Avatar
        :src="profile.profile_picture_url || ''"
        :name="profile.profile_name || formattedPhone || 'WhatsApp'"
        :size="40"
        rounded-full
      />
      <div class="flex flex-col min-w-0">
        <span class="text-sm font-medium text-n-slate-12 truncate">
          {{
            profile.profile_name ||
            $t('INBOX_MGMT.EVOLUTION_CONNECTION.UNKNOWN_PROFILE')
          }}
        </span>
        <span v-if="formattedPhone" class="text-xs text-n-slate-11">
          {{ formattedPhone }}
        </span>
      </div>
    </div>

    <div
      v-if="showQr"
      class="flex flex-col sm:flex-row gap-6 items-start p-4 rounded-xl border border-n-weak"
    >
      <div
        class="flex items-center justify-center size-64 shrink-0 rounded-lg bg-white p-2"
      >
        <img
          v-if="qrCode"
          :src="qrCode"
          :alt="$t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_ALT')"
          class="size-full"
        />
        <Spinner v-else class="size-6 text-n-slate-10" />
      </div>
      <div class="flex flex-col gap-3 text-sm text-n-slate-11">
        <p class="font-medium text-n-slate-12">
          {{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_TITLE') }}
        </p>
        <ol class="list-decimal ps-5 space-y-1">
          <li>{{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_STEPS.OPEN') }}</li>
          <li>{{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_STEPS.DEVICES') }}</li>
          <li>{{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_STEPS.SCAN') }}</li>
        </ol>
        <p v-if="pairingCode" class="text-xs">
          {{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.PAIRING_CODE') }}
          <span class="font-mono font-medium text-n-slate-12">
            {{ pairingCode }}
          </span>
        </p>
        <p class="text-xs">
          {{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.QR_HINT') }}
        </p>
      </div>
    </div>

    <p v-if="status === 'expired'" class="text-sm text-n-slate-11">
      {{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.EXPIRED_HINT') }}
    </p>

    <div class="flex flex-wrap items-center gap-2">
      <NextButton
        v-if="canRequestQr && errorCode !== 'not_configured'"
        type="button"
        size="sm"
        icon="i-lucide-qr-code"
        :label="
          status === 'close'
            ? $t('INBOX_MGMT.EVOLUTION_CONNECTION.CONNECT')
            : $t('INBOX_MGMT.EVOLUTION_CONNECTION.NEW_QR')
        "
        :is-loading="requestingQr"
        @click="startConnection"
      />
      <NextButton
        v-if="showQr"
        type="button"
        size="sm"
        variant="faded"
        color="slate"
        icon="i-lucide-refresh-cw"
        :label="$t('INBOX_MGMT.EVOLUTION_CONNECTION.NEW_QR')"
        :is-loading="requestingQr"
        @click="startConnection"
      />
      <template v-if="isConnected">
        <NextButton
          v-if="!confirmingLogout"
          type="button"
          size="sm"
          variant="faded"
          color="ruby"
          icon="i-lucide-unplug"
          :label="$t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT')"
          @click="confirmingLogout = true"
        />
        <template v-else>
          <span class="text-sm text-n-slate-11">
            {{ $t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT_CONFIRM') }}
          </span>
          <NextButton
            type="button"
            size="sm"
            color="ruby"
            :label="$t('INBOX_MGMT.EVOLUTION_CONNECTION.LOGOUT')"
            :is-loading="loggingOut"
            @click="logout"
          />
          <NextButton
            type="button"
            size="sm"
            variant="ghost"
            color="slate"
            :label="$t('INBOX_MGMT.EVOLUTION_CONNECTION.CANCEL')"
            @click="confirmingLogout = false"
          />
        </template>
      </template>
    </div>
  </div>
</template>
