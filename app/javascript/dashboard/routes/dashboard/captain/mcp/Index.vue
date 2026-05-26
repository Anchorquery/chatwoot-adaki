<script setup>
import { computed, nextTick, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useMapGetter, useStore } from 'dashboard/composables/store';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { usePolicy } from 'dashboard/composables/usePolicy';
import { useAccount } from 'dashboard/composables/useAccount';

import PageLayout from 'dashboard/components-next/captain/PageLayout.vue';
import CaptainPaywall from 'dashboard/components-next/captain/pageComponents/Paywall.vue';
import McpServersPageEmptyState from 'dashboard/components-next/captain/pageComponents/mcp/McpServersPageEmptyState.vue';
import CreateMcpServerDialog from 'dashboard/components-next/captain/pageComponents/mcp/CreateMcpServerDialog.vue';
import McpServerCard from 'dashboard/components-next/captain/pageComponents/mcp/McpServerCard.vue';
import DeleteDialog from 'dashboard/components-next/captain/pageComponents/DeleteDialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const store = useStore();
const { shouldShowPaywall } = usePolicy();
const { accountScopedRoute } = useAccount();
const router = useRouter();

const uiFlags = useMapGetter('captainMcpServers/getUIFlags');
const servers = useMapGetter('captainMcpServers/getRecords');
const serversMeta = useMapGetter('captainMcpServers/getMeta');
const isFetching = computed(() => uiFlags.value.fetchingList);

const createDialogRef = ref(null);
const deleteDialogRef = ref(null);
const selectedServer = ref(null);
const dialogType = ref('');

const fetchServers = () => store.dispatch('captainMcpServers/get');

const openCreateDialog = () => {
  dialogType.value = 'create';
  selectedServer.value = null;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleEdit = server => {
  dialogType.value = 'edit';
  selectedServer.value = server;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleDelete = server => {
  selectedServer.value = server;
  nextTick(() => deleteDialogRef.value.dialogRef.open());
};

const handleAction = ({ action, id }) => {
  const server = servers.value.find(item => item.id === id);
  if (!server) return;

  if (action === 'edit') handleEdit(server);
  if (action === 'delete') handleDelete(server);
  if (action === 'discover') store.dispatch('captainMcpServers/discover', id);
  if (action === 'test') store.dispatch('captainMcpServers/test', id);
};

const handleDialogClose = () => {
  dialogType.value = '';
  selectedServer.value = null;
};

const onDeleteSuccess = () => {
  selectedServer.value = null;
  fetchServers();
};

const openProvidersSettings = () => {
  router.push(accountScopedRoute('captain_providers_index'));
};

onMounted(() => {
  if (!shouldShowPaywall(FEATURE_FLAGS.CAPTAIN_MCP)) {
    fetchServers();
  }
});
</script>

<template>
  <PageLayout
    :header-title="$t('CAPTAIN.MCP.HEADER')"
    :button-label="$t('CAPTAIN.MCP.ADD_NEW')"
    :button-policy="['administrator']"
    :feature-flag="FEATURE_FLAGS.CAPTAIN_MCP"
    :total-count="serversMeta.totalCount"
    :current-page="serversMeta.page"
    :show-pagination-footer="false"
    :is-fetching="isFetching"
    :is-empty="!servers.length"
    :show-know-more="false"
    @click="openCreateDialog"
  >
    <template #paywall>
      <CaptainPaywall feature-prefix="CAPTAIN.MCP" />
    </template>

    <template #action>
      <Button
        variant="outline"
        color="slate"
        size="sm"
        icon="i-lucide-sliders-horizontal"
        :label="$t('CAPTAIN.MCP.MANAGE_PROVIDERS')"
        @click="openProvidersSettings"
      />
    </template>

    <template #emptyState>
      <McpServersPageEmptyState @click="openCreateDialog" />
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <McpServerCard
          v-for="server in servers"
          :id="server.id"
          :key="server.id"
          :name="server.name"
          :description="server.description"
          :endpoint-url="server.endpoint_url"
          :transport-type="server.transport_type"
          :enabled="server.enabled"
          :tools-count="server.tools_count"
          :credential-hint="server.credential_hint"
          :last-discovered-at="server.last_discovered_at"
          :updated-at="server.updated_at"
          @action="handleAction"
        />
      </div>
    </template>
  </PageLayout>

  <CreateMcpServerDialog
    v-if="dialogType"
    ref="createDialogRef"
    :type="dialogType"
    :selected-server="selectedServer"
    @close="handleDialogClose"
  />

  <DeleteDialog
    v-if="selectedServer"
    ref="deleteDialogRef"
    :entity="selectedServer"
    type="McpServers"
    translation-key="MCP"
    @delete-success="onDeleteSuccess"
  />
</template>
