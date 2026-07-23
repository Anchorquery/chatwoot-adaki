<script setup>
import { computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import EvolutionPrivacyFilter from './components/EvolutionPrivacyFilter.vue';

// Pagina propia (no una pestaña mas de Settings.vue) porque esa ruta entera
// es admin-only (`permissions: ['administrator']`) y este control es
// justamente lo que un agente sin acceso de administrador (ni al Manager de
// Evolution) necesita poder operar solo.
const { t } = useI18n();
const route = useRoute();
const store = useStore();

const inboxId = computed(() => route.params.inboxId);
const getInbox = useMapGetter('inboxes/getInbox');
const inbox = computed(() => getInbox.value(inboxId.value) || {});
const evolutionVerified = computed(
  () => inbox.value.additional_attributes?.evolution_verified === true
);

onMounted(() => {
  if (!inbox.value.id) {
    store.dispatch('inboxes/get');
  }
});
</script>

<template>
  <div class="flex flex-col gap-4 p-4 max-w-2xl">
    <div>
      <h3 class="text-lg font-medium text-n-slate-12">
        {{ t('INBOX_MGMT.SETTINGS_POPUP.EVOLUTION_PRIVACY.LABEL') }}
      </h3>
      <p v-if="inbox.name" class="text-sm text-n-slate-11">
        {{ inbox.name }}
      </p>
    </div>
    <EvolutionPrivacyFilter
      v-if="inboxId"
      :inbox-id="inboxId"
      :connected="evolutionVerified"
    />
  </div>
</template>
