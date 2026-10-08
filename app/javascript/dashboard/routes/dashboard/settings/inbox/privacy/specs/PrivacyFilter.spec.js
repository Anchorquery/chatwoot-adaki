import { mount, flushPromises } from '@vue/test-utils';
import InboxesAPI from 'dashboard/api/inboxes';
import PrivacyFilter from '../../PrivacyFilter.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { inboxId: '7' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useStore: () => ({ dispatch: vi.fn() }),
    useMapGetter: () => computed(() => () => ({ id: 7, name: 'Ventas' })),
  };
});
vi.mock('dashboard/api/inboxes', () => ({
  default: {
    getEvolutionPrivacyFilter: vi.fn(),
    updateEvolutionPrivacyFilter: vi.fn(),
    resolveEvolutionPrivacy: vi.fn(),
    searchEvolutionPrivacy: vi.fn(),
  },
}));

const mountPage = () =>
  mount(PrivacyFilter, {
    global: {
      mocks: { $t: key => key },
      stubs: { Avatar: true, Spinner: true },
    },
  });

// vitest.setup.js sustituye NextButton por un <button> sin props: el label
// queda como atributo.
const buttonLabelled = (wrapper, label) =>
  wrapper
    .findAll('button')
    .find(button => button.attributes('label') === label);

const saveButton = wrapper => buttonLabelled(wrapper, 'PRIVACY_FILTER.SAVE');

describe('Privacy filter page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    InboxesAPI.getEvolutionPrivacyFilter.mockResolvedValue({
      data: {
        mode: 'block',
        conflict: false,
        // El Manager de Evolution guarda números pelados.
        contact_jids: ['34600111222'],
        group_jids: ['1@g.us'],
        channel_jids: [],
      },
    });
    InboxesAPI.resolveEvolutionPrivacy.mockResolvedValue({
      data: {
        labels: {
          '34600111222@s.whatsapp.net': { name: 'Juan', phone: '34600111222' },
        },
      },
    });
    InboxesAPI.searchEvolutionPrivacy.mockResolvedValue({
      data: { items: [], has_more: false },
    });
    InboxesAPI.updateEvolutionPrivacyFilter.mockResolvedValue({ data: {} });
  });

  it('shows the saved chats with their names', async () => {
    const wrapper = mountPage();
    await flushPromises();

    expect(InboxesAPI.resolveEvolutionPrivacy).toHaveBeenCalledWith('7', [
      '34600111222@s.whatsapp.net',
      '1@g.us',
    ]);
    expect(wrapper.text()).toContain('Juan');
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
  });

  it('lets a number typed by hand be added and saved with its label', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('input[type="search"]').setValue('+34 611 222 333');
    await vi.waitFor(() =>
      expect(wrapper.text()).toContain('PRIVACY_FILTER.SEARCH.MANUAL')
    );
    const manualAdd = buttonLabelled(
      wrapper,
      'PRIVACY_FILTER.SEARCH.ADD_BLOCK'
    );
    await manualAdd.trigger('click');
    await saveButton(wrapper).trigger('click');
    await flushPromises();

    expect(InboxesAPI.updateEvolutionPrivacyFilter).toHaveBeenCalledWith('7', {
      mode: 'block',
      jids: [
        '34611222333@s.whatsapp.net',
        '34600111222@s.whatsapp.net',
        '1@g.us',
      ],
      labels: { '34600111222@s.whatsapp.net': 'Juan' },
    });
  });

  // Llevar la lista de "bloquear" a "solo estos" convertiría a los bloqueados
  // en los únicos que llegan.
  it('starts an empty list when switching between block and allow', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const allowMode = wrapper
      .findAll('[role="radio"]')
      .find(radio => radio.text().includes('PRIVACY_FILTER.MODES.ALLOW.TITLE'));
    await allowMode.trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('PRIVACY_FILTER.SELECTED.EMPTY_ALLOW');
    expect(wrapper.text()).toContain('PRIVACY_FILTER.MISSING_SELECTION');
    expect(saveButton(wrapper).attributes('disabled')).toBeDefined();
  });

  it('does not allow saving when the current filter could not be read', async () => {
    InboxesAPI.getEvolutionPrivacyFilter.mockRejectedValue(new Error('down'));
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.text()).toContain('PRIVACY_FILTER.LOAD_ERROR');
    expect(saveButton(wrapper)).toBeUndefined();
  });
});
