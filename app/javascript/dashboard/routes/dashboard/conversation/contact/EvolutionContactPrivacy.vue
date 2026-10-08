<script setup>
import { ref, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  inboxId: {
    type: Number,
    required: true,
  },
  contactId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();

// loading | ready | error
const state = ref('loading');
const filtered = ref(false);
const mode = ref('all');
const saving = ref(false);
const confirmDialog = ref(null);

const statusText = computed(() =>
  filtered.value
    ? t('PRIVACY_FILTER.CONTACT.FILTERED')
    : t('PRIVACY_FILTER.CONTACT.RECEIVING')
);

const ERRORS = {
  last_allowed: 'PRIVACY_FILTER.CONTACT.ERRORS.LAST_ALLOWED',
  no_jid: 'PRIVACY_FILTER.CONTACT.ERRORS.NO_JID',
};

const load = async () => {
  state.value = 'loading';
  try {
    const { data } = await InboxesAPI.getEvolutionPrivacyContact(
      props.inboxId,
      props.contactId
    );
    filtered.value = Boolean(data.filtered);
    mode.value = data.mode || 'all';
    state.value = 'ready';
  } catch {
    state.value = 'error';
  }
};

const update = async value => {
  saving.value = true;
  try {
    await InboxesAPI.updateEvolutionPrivacyContact(
      props.inboxId,
      props.contactId,
      value
    );
    filtered.value = value;
    confirmDialog.value?.close();
    useAlert(
      value
        ? t('PRIVACY_FILTER.CONTACT.EXCLUDED_ALERT')
        : t('PRIVACY_FILTER.CONTACT.INCLUDED_ALERT')
    );
  } catch (error) {
    const key = ERRORS[error?.response?.data?.message];
    useAlert(t(key || 'PRIVACY_FILTER.CONTACT.ERRORS.GENERIC'));
  } finally {
    saving.value = false;
  }
};

const askExclude = () => confirmDialog.value?.open();

watch(
  () => [props.inboxId, props.contactId],
  () => load(),
  { immediate: true }
);
</script>

<template>
  <div
    class="flex flex-col gap-2 p-3 mx-4 mt-2 rounded-xl border border-n-weak"
  >
    <div class="flex items-center gap-2">
      <span class="i-lucide-shield-check size-4 text-n-slate-10 shrink-0" />
      <span class="text-sm font-medium text-n-slate-12 flex-1">
        {{ $t('PRIVACY_FILTER.CONTACT.TITLE') }}
      </span>
      <Spinner v-if="state === 'loading'" class="size-3.5 text-n-slate-10" />
    </div>

    <template v-if="state === 'ready'">
      <p
        class="text-xs"
        :class="filtered ? 'text-n-amber-11' : 'text-n-slate-11'"
      >
        {{ statusText }}
      </p>
      <div class="flex items-center gap-2">
        <NextButton
          v-if="!filtered"
          type="button"
          size="xs"
          variant="faded"
          color="ruby"
          icon="i-lucide-ban"
          :label="$t('PRIVACY_FILTER.CONTACT.EXCLUDE')"
          @click="askExclude"
        />
        <NextButton
          v-else
          type="button"
          size="xs"
          variant="faded"
          color="slate"
          icon="i-lucide-undo-2"
          :label="$t('PRIVACY_FILTER.CONTACT.INCLUDE')"
          :is-loading="saving"
          @click="update(false)"
        />
        <router-link
          :to="{
            name: 'settings_inbox_privacy_filter',
            params: { inboxId },
          }"
          class="text-xs text-n-slate-11 hover:text-n-slate-12 hover:underline"
        >
          {{ $t('PRIVACY_FILTER.CONTACT.MANAGE') }}
        </router-link>
      </div>
    </template>

    <div v-else-if="state === 'error'" class="flex items-center gap-2">
      <p class="text-xs text-n-slate-11 flex-1">
        {{ $t('PRIVACY_FILTER.CONTACT.LOAD_ERROR') }}
      </p>
      <NextButton
        type="button"
        size="xs"
        variant="ghost"
        color="slate"
        icon="i-lucide-refresh-cw"
        :aria-label="$t('PRIVACY_FILTER.RETRY')"
        @click="load"
      />
    </div>

    <Dialog
      ref="confirmDialog"
      type="alert"
      :title="$t('PRIVACY_FILTER.CONTACT.CONFIRM_TITLE')"
      :description="
        mode === 'allow'
          ? $t('PRIVACY_FILTER.CONTACT.CONFIRM_ALLOW_MODE')
          : $t('PRIVACY_FILTER.CONTACT.CONFIRM_DESCRIPTION')
      "
      :confirm-button-label="$t('PRIVACY_FILTER.CONTACT.EXCLUDE')"
      :is-loading="saving"
      @confirm="update(true)"
    />
  </div>
</template>
