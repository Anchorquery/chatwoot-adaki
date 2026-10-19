import {
  AVAILABLE_CUSTOM_ROLE_PERMISSIONS,
  CUSTOM_ROLE_PERMISSION_GROUPS,
  CUSTOM_ROLE_PRESETS,
} from 'dashboard/constants/permissions';

describe('custom role permission catalog', () => {
  it('lists every permission in exactly one section', () => {
    const grouped = CUSTOM_ROLE_PERMISSION_GROUPS.flatMap(
      group => group.permissions
    );

    expect(grouped).toEqual(AVAILABLE_CUSTOM_ROLE_PERMISSIONS);
    expect(new Set(grouped).size).toBe(grouped.length);
  });

  it('only builds templates from known permissions', () => {
    Object.values(CUSTOM_ROLE_PRESETS).forEach(permissions => {
      permissions.forEach(permission => {
        expect(AVAILABLE_CUSTOM_ROLE_PERMISSIONS).toContain(permission);
      });
    });
  });
});
