import { ref } from 'vue';
import { useAdmin } from '../useAdmin';
import { useStoreGetters } from 'dashboard/composables/store';

vi.mock('dashboard/composables/store');

describe('useAdmin', () => {
  it('returns true if the current user is an administrator', () => {
    useStoreGetters.mockReturnValue({
      getCurrentRole: ref('administrator'),
    });

    const { isAdmin } = useAdmin();
    expect(isAdmin.value).toBe(true);
  });

  it('returns false if the current user is not an administrator', () => {
    useStoreGetters.mockReturnValue({
      getCurrentRole: ref('user'),
    });

    const { isAdmin } = useAdmin();
    expect(isAdmin.value).toBe(false);
  });

  it('returns false if the current user role is null', () => {
    useStoreGetters.mockReturnValue({
      getCurrentRole: ref(null),
    });

    const { isAdmin } = useAdmin();
    expect(isAdmin.value).toBe(false);
  });

  it('returns false if the current user role is undefined', () => {
    useStoreGetters.mockReturnValue({
      getCurrentRole: ref(undefined),
    });

    const { isAdmin } = useAdmin();
    expect(isAdmin.value).toBe(false);
  });

  it('returns false if the current user role is an empty string', () => {
    useStoreGetters.mockReturnValue({
      getCurrentRole: ref(''),
    });

    const { isAdmin } = useAdmin();
    expect(isAdmin.value).toBe(false);
  });

  describe('section permissions', () => {
    const withUser = (role, permissions) =>
      useStoreGetters.mockReturnValue({
        getCurrentRole: ref(role),
        getCurrentPermissions: ref(permissions),
      });

    it('lets an administrator manage every section', () => {
      withUser('administrator', ['administrator']);

      const { canManageInboxes, canManageTeams } = useAdmin();
      expect(canManageInboxes.value).toBe(true);
      expect(canManageTeams.value).toBe(true);
    });

    it('only opens the sections the custom role was given', () => {
      withUser('agent', ['inbox_manage', 'custom_role']);

      const { canManageInboxes, canManageTeams } = useAdmin();
      expect(canManageInboxes.value).toBe(true);
      expect(canManageTeams.value).toBe(false);
    });

    it('does not open channel administration for channel operators', () => {
      withUser('agent', ['channel_operate', 'custom_role']);

      const { canManageInboxes } = useAdmin();
      expect(canManageInboxes.value).toBe(false);
    });
  });
});
