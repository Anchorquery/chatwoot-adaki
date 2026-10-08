<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useMapGetter } from 'dashboard/composables/store';
import NextButton from 'dashboard/components-next/button/Button.vue';
import EvolutionConnection from '../components/EvolutionConnection.vue';

const { t } = useI18n();
const router = useRouter();
const store = useStore();

const uiFlags = useMapGetter('inboxes/getUIFlags');

const inboxName = ref('');
const nameError = ref('');
const createdInbox = ref(null);
const connected = ref(false);

const isCreating = computed(() => uiFlags.value.isCreating);

const CREATE_ERRORS = {
  name_taken: 'NAME_TAKEN',
  not_configured: 'NOT_CONFIGURED',
  name_required: 'NAME_REQUIRED',
};

const createInbox = async () => {
  const name = inboxName.value.trim();
  if (!name) {
    nameError.value = t('INBOX_MGMT.ADD.EVOLUTION.ERRORS.NAME_REQUIRED');
    return;
  }
  nameError.value = '';

  try {
    createdInbox.value = await store.dispatch(
      'inboxes/createEvolutionChannel',
      { name }
    );
  } catch (error) {
    const key = CREATE_ERRORS[error?.response?.data?.error] || 'GENERIC';
    const message = t(`INBOX_MGMT.ADD.EVOLUTION.ERRORS.${key}`);
    if (key === 'NAME_TAKEN' || key === 'NAME_REQUIRED') {
      nameError.value = message;
    } else {
      useAlert(message);
    }
  }
};

const goToAgents = () => {
  router.replace({
    name: 'settings_inboxes_add_agents',
    params: { page: 'new', inbox_id: createdInbox.value.id },
  });
};
</script>

<template>
  <div class="flex flex-col gap-6">
    <div>
      <h2 class="mb-1 text-base font-medium text-n-slate-12">
        {{ $t('INBOX_MGMT.ADD.EVOLUTION.TITLE') }}
      </h2>
      <p class="text-sm text-n-slate-11">
        {{
          createdInbox
            ? $t('INBOX_MGMT.ADD.EVOLUTION.SCAN_DESC')
            : $t('INBOX_MGMT.ADD.EVOLUTION.DESC')
        }}
      </p>
    </div>

    <form
      v-if="!createdInbox"
      class="flex flex-col gap-4"
      @submit.prevent="createInbox"
    >
      <label :class="{ error: nameError }">
        {{ $t('INBOX_MGMT.ADD.EVOLUTION.NAME.LABEL') }}
        <input
          v-model="inboxName"
          type="text"
          maxlength="100"
          :placeholder="$t('INBOX_MGMT.ADD.EVOLUTION.NAME.PLACEHOLDER')"
        />
        <span v-if="nameError" class="message">{{ nameError }}</span>
      </label>
      <p class="text-xs text-n-slate-11 -mt-2">
        {{ $t('INBOX_MGMT.ADD.EVOLUTION.NAME.HELP') }}
      </p>
      <div>
        <NextButton
          type="submit"
          icon="i-lucide-qr-code"
          :is-loading="isCreating"
          :label="$t('INBOX_MGMT.ADD.EVOLUTION.SUBMIT')"
        />
      </div>
    </form>

    <template v-else>
      <EvolutionConnection
        :inbox-id="createdInbox.id"
        auto-connect
        @connected="connected = true"
        @disconnected="connected = false"
      />
      <div class="flex items-center gap-3 pt-4 border-t border-n-weak">
        <NextButton
          :label="
            connected
              ? $t('INBOX_MGMT.ADD.EVOLUTION.CONTINUE')
              : $t('INBOX_MGMT.ADD.EVOLUTION.SKIP')
          "
          :variant="connected ? 'solid' : 'faded'"
          :color="connected ? 'blue' : 'slate'"
          @click="goToAgents"
        />
        <span v-if="!connected" class="text-xs text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.EVOLUTION.SKIP_HINT') }}
        </span>
      </div>
    </template>
  </div>
</template>
