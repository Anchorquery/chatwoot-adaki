<script setup>
import Button from 'dashboard/components-next/button/Button.vue';

const emit = defineEmits(['click']);
</script>

<template>
  <div
    class="flex flex-col items-start gap-3 p-6 border rounded-xl border-n-weak bg-n-surface-1"
  >
    <div class="flex items-center gap-2 text-n-slate-12">
      <span class="i-lucide-plug-zap size-5" />
      <span class="text-base font-medium">{{
        $t('CAPTAIN.MCP.EMPTY_STATE.TITLE')
      }}</span>
    </div>
    <p class="max-w-2xl text-sm text-n-slate-11">
      {{ $t('CAPTAIN.MCP.EMPTY_STATE.SUBTITLE') }}
    </p>
    <Button
      color="blue"
      :label="$t('CAPTAIN.MCP.ADD_NEW')"
      icon="i-lucide-plus"
      @click="emit('click')"
    />
  </div>
</template>
