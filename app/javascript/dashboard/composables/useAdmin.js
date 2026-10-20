import { computed } from 'vue';
import { useStoreGetters } from 'dashboard/composables/store';

/**
 * Composable to determine if the current user is an administrator, and which
 * sections a custom role lets them manage.
 * @returns {Object} - isAdmin plus one flag per managed section.
 */
export function useAdmin() {
  const getters = useStoreGetters();

  const currentUserRole = computed(() => getters.getCurrentRole.value);
  const isAdmin = computed(() => currentUserRole.value === 'administrator');
  const can = permission =>
    computed(
      () =>
        isAdmin.value ||
        getters.getCurrentPermissions.value.includes(permission)
    );

  return {
    isAdmin,
    canManageInboxes: can('inbox_manage'),
    canManageTeams: can('team_manage'),
    canManageMacros: can('macro_manage'),
  };
}
