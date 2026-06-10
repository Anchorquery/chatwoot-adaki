<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStoreGetters } from 'dashboard/composables/store';

const getters = useStoreGetters();
const { t } = useI18n();
const globalConfig = computed(() => getters['globalConfig/get'].value);
const currentUser = computed(() => getters.getCurrentUser.value);

const greetingMessage = computed(() => {
  const hours = new Date().getHours();
  let translationKey;
  if (hours < 12) {
    translationKey = 'ONBOARDING.GREETING_MORNING';
  } else if (hours < 18) {
    translationKey = 'ONBOARDING.GREETING_AFTERNOON';
  } else {
    translationKey = 'ONBOARDING.GREETING_EVENING';
  }
  return t(translationKey, {
    name: currentUser.value.name,
    installationName: globalConfig.value.installationName,
  });
});
</script>

<template>
  <div
    class="min-h-screen max-w-4xl mx-auto flex items-center justify-center p-8 w-full font-inter overflow-auto"
  >
    <p
      class="text-xl font-semibold text-n-slate-12 font-interDisplay tracking-[0.3px]"
    >
      {{ greetingMessage }}
    </p>
  </div>
</template>
