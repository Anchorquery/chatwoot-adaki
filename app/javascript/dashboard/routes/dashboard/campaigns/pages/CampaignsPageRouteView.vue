<script setup>
import { onMounted } from 'vue';
import { useStore } from 'dashboard/composables/store';

defineProps({
  keepAlive: { type: Boolean, default: true },
});

const store = useStore();

// El editor no se cachea: volver a "Nueva campaña" mostraría el formulario anterior.
const NOT_CACHED = ['APICampaignEditorPage'];

onMounted(() => {
  store.dispatch('labels/get');
});
</script>

<template>
  <div
    class="flex flex-col justify-between flex-1 h-full m-0 overflow-auto bg-n-surface-1"
  >
    <router-view v-slot="{ Component }">
      <keep-alive v-if="keepAlive" :exclude="NOT_CACHED">
        <component :is="Component" />
      </keep-alive>
      <component :is="Component" v-else />
    </router-view>
  </div>
</template>
