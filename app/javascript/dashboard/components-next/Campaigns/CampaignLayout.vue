<script setup>
import Button from 'dashboard/components-next/button/Button.vue';

defineProps({
  headerTitle: {
    type: String,
    default: '',
  },
  buttonLabel: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['click', 'close']);

const handleButtonClick = () => {
  emit('click');
};
</script>

<template>
  <section class="flex flex-col w-full h-full overflow-hidden bg-n-surface-1">
    <header class="sticky top-0 z-10 px-6">
      <div class="w-full max-w-5xl mx-auto">
        <div class="flex items-center justify-between w-full h-20 gap-2">
          <span class="text-heading-1 text-n-slate-12">
            {{ headerTitle }}
          </span>
          <div class="relative group/campaign-button">
            <Button
              :label="buttonLabel"
              icon="i-lucide-plus"
              size="sm"
              class="group-hover/campaign-button:brightness-110"
              @click="handleButtonClick"
            />
            <slot name="action" />
          </div>
        </div>
      </div>
    </header>
    <div v-if="$slots.filters" class="px-6 border-b border-n-weak">
      <div class="w-full max-w-5xl mx-auto">
        <slot name="filters" />
      </div>
    </div>
    <main class="flex-1 px-6 overflow-y-auto flex flex-col min-h-0">
      <div class="w-full max-w-5xl mx-auto py-4 flex-1">
        <slot name="default" />
      </div>
      <div v-if="$slots.pagination" class="w-full max-w-5xl mx-auto">
        <slot name="pagination" />
      </div>
    </main>
  </section>
</template>
