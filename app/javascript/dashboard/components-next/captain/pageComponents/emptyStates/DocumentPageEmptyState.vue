<script setup>
import { useAccount } from 'dashboard/composables/useAccount';
import { useBranding } from 'shared/composables/useBranding';
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import DocumentCard from 'dashboard/components-next/captain/assistant/DocumentCard.vue';
import FeatureSpotlight from 'dashboard/components-next/feature-spotlight/FeatureSpotlight.vue';
import { documentsList } from 'dashboard/components-next/captain/pageComponents/emptyStates/captainEmptyStateContent.js';

const emit = defineEmits(['click']);
const { isOnChatwootCloud } = useAccount();

const { replaceInstallationName } = useBranding();

const onClick = () => {
  emit('click');
};
</script>

<template>
  <div
    class="mb-6 rounded-2xl border border-n-weak bg-gradient-to-br from-n-slate-2 via-n-slate-1 to-n-slate-3 p-5"
  >
    <p class="m-0 text-xs font-semibold uppercase tracking-[0.2em] text-n-slate-11">
      {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.TITLE') }}
    </p>
    <div class="mt-4 grid gap-3 md:grid-cols-3">
      <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-4">
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.PDFS.TITLE') }}
        </p>
        <p class="mt-1 mb-0 text-sm text-n-slate-11">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.PDFS.SUBTITLE') }}
        </p>
      </div>
      <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-4">
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.WEB.TITLE') }}
        </p>
        <p class="mt-1 mb-0 text-sm text-n-slate-11">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.WEB.SUBTITLE') }}
        </p>
      </div>
      <div class="rounded-xl border border-n-weak bg-n-alpha-2 p-4">
        <p class="m-0 text-sm font-medium text-n-slate-12">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.SYNC.TITLE') }}
        </p>
        <p class="mt-1 mb-0 text-sm text-n-slate-11">
          {{ $t('CAPTAIN.DOCUMENTS.EMPTY_STATE.KNOWLEDGE_PANEL.SYNC.SUBTITLE') }}
        </p>
      </div>
    </div>
  </div>
  <FeatureSpotlight
    :title="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.FEATURE_SPOTLIGHT.TITLE')"
    :note="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.FEATURE_SPOTLIGHT.NOTE')"
    fallback-thumbnail="/assets/images/dashboard/captain/document-light.svg"
    fallback-thumbnail-dark="/assets/images/dashboard/captain/document-dark.svg"
    learn-more-url="https://chwt.app/captain-document"
    :hide-actions="!isOnChatwootCloud"
    class="mb-8"
  />
  <EmptyStateLayout
    :title="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.TITLE')"
    :subtitle="$t('CAPTAIN.DOCUMENTS.EMPTY_STATE.SUBTITLE')"
    :action-perms="['administrator']"
  >
    <template #empty-state-item>
      <div class="grid grid-cols-1 gap-4 p-px overflow-hidden">
        <DocumentCard
          v-for="(document, index) in documentsList.slice(0, 5)"
          :id="document.id"
          :key="`document-${index}`"
          :name="replaceInstallationName(document.name)"
          :assistant="document.assistant"
          :external-link="document.external_link"
          :created-at="document.created_at"
        />
      </div>
    </template>
    <template #actions>
      <Button
        :label="$t('CAPTAIN.DOCUMENTS.ADD_NEW')"
        icon="i-lucide-plus"
        @click="onClick"
      />
    </template>
  </EmptyStateLayout>
</template>
