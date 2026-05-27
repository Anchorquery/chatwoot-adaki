import { ref, computed, watch, onMounted, onActivated } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';

export function useCampaignList(channelTypes) {
  const store = useStore();

  const filters = ref({ status: '', q: '' });
  const currentPage = ref(1);

  const campaigns = computed(() => store.getters['campaigns/getAllCampaigns']);
  const meta = useMapGetter('campaigns/getMeta');
  const uiFlags = useMapGetter('campaigns/getUIFlags');
  const isFetching = computed(() => uiFlags.value.isFetching);

  async function fetch() {
    await store.dispatch('campaigns/get', {
      page: currentPage.value,
      status: filters.value.status,
      channelTypes,
      q: filters.value.q,
    });
  }

  function onFilterChange(newFilters) {
    filters.value = { ...newFilters };
    currentPage.value = 1;
  }

  function onPageChange(page) {
    currentPage.value = page;
  }

  // watch filters and page changes — each page starts from 1 on filter change
  watch([filters, currentPage], fetch, { deep: true });

  onMounted(fetch);
  onActivated(fetch);

  return {
    campaigns,
    meta,
    isFetching,
    filters,
    currentPage,
    onFilterChange,
    onPageChange,
    refresh: fetch,
  };
}
