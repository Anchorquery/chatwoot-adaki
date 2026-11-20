<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  inboxId: {
    type: [String, Number],
    required: true,
  },
});

const { t } = useI18n();

const syncing = ref(false);
const result = ref(null);
const failed = ref(false);

const syncGroups = async () => {
  syncing.value = true;
  failed.value = false;
  result.value = null;
  try {
    const { data } = await InboxesAPI.syncEvolutionGroupContacts(props.inboxId);
    result.value = data;
  } catch {
    failed.value = true;
  } finally {
    syncing.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col items-start gap-2">
    <NextButton
      size="sm"
      color="slate"
      :label="t('INBOX_MGMT.EVOLUTION_GROUP_CONTACTS.BUTTON')"
      :is-loading="syncing"
      @click="syncGroups"
    />
    <p v-if="result" class="text-xs text-n-teal-11">
      {{ t('INBOX_MGMT.EVOLUTION_GROUP_CONTACTS.SUCCESS', result) }}
      <span v-if="result.failed" class="text-n-ruby-11">
        {{ t('INBOX_MGMT.EVOLUTION_GROUP_CONTACTS.PARTIAL', result) }}
      </span>
    </p>
    <p v-if="failed" class="text-xs text-n-ruby-11">
      {{ t('INBOX_MGMT.EVOLUTION_GROUP_CONTACTS.ERROR') }}
    </p>
  </div>
</template>
