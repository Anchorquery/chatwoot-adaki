import { mount, flushPromises } from '@vue/test-utils';
import {
  AVAILABLE_CUSTOM_ROLE_PERMISSIONS,
  CUSTOM_ROLE_PERMISSION_GROUPS,
} from 'dashboard/constants/permissions';
import CustomRoleModal from '../component/CustomRoleModal.vue';

const { dispatch } = vi.hoisted(() => ({ dispatch: vi.fn() }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('dashboard/composables/store', () => ({
  useStore: () => ({ dispatch }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const mountModal = (props = {}) =>
  mount(CustomRoleModal, {
    props,
    global: {
      mocks: { $t: key => key },
      stubs: { 'woot-modal-header': true, Button: false },
    },
  });

const checked = wrapper =>
  wrapper
    .findAll('input[type=checkbox]')
    .filter(box => box.element.checked)
    .map(box => box.element.value);

describe('CustomRoleModal', () => {
  beforeEach(() => {
    dispatch.mockReset();
    dispatch.mockResolvedValue({});
  });

  it('shows one titled section per area with its permissions', () => {
    const wrapper = mountModal();

    const titles = wrapper.findAll('legend').map(legend => legend.text());
    expect(titles).toEqual(
      CUSTOM_ROLE_PERMISSION_GROUPS.map(
        group => `CUSTOM_ROLE.PERMISSION_GROUPS.${group.key.toUpperCase()}`
      )
    );
    expect(wrapper.findAll('input[type=checkbox]')).toHaveLength(
      AVAILABLE_CUSTOM_ROLE_PERMISSIONS.length
    );
  });

  it('ticks the permissions of a template without losing the ones already ticked', async () => {
    const wrapper = mountModal();
    await wrapper.find('input[value=report_manage]').setValue(true);

    const communication = wrapper
      .findAll('button')
      .find(button => button.text().includes('PRESETS.COMMUNICATION'));
    await communication.trigger('click');

    expect(checked(wrapper)).toEqual(
      expect.arrayContaining([
        'report_manage',
        'campaign_manage',
        'contact_manage',
        'channel_operate',
        'conversation_manage',
      ])
    );
    expect(checked(wrapper)).not.toContain('inbox_manage');
  });

  it('loads the permissions of the role being edited and clears any legacy profile on save', async () => {
    const wrapper = mountModal({
      mode: 'edit',
      selectedRole: {
        id: 7,
        name: 'Comms',
        description: 'Campaigns',
        permissions: ['campaign_manage', 'channel_operate'],
        sidebar_profile: 'communication',
      },
    });

    await flushPromises();
    expect(checked(wrapper)).toEqual(['campaign_manage', 'channel_operate']);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(dispatch).toHaveBeenCalledWith(
      'customRole/updateCustomRole',
      expect.objectContaining({
        id: 7,
        permissions: ['campaign_manage', 'channel_operate'],
        sidebar_profile: null,
      })
    );
  });
});
