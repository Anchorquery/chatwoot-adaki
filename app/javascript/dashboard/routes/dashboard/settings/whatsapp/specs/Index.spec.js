import { mount, flushPromises } from '@vue/test-utils';
import InboxesAPI from 'dashboard/api/inboxes';
import WhatsappConnections from '../Index.vue';

const { inboxes } = vi.hoisted(() => ({ inboxes: { value: [] } }));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${JSON.stringify(params)}` : key),
  }),
}));
vi.mock('vue-router', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useMapGetter: getter =>
      getter === 'inboxes/getInboxes'
        ? computed(() => inboxes.value)
        : computed(() => ({ isFetching: false })),
  };
});
// Estos componentes importan el router real de la app; aquí solo hace falta
// que pinten sus slots o nada.
vi.mock('dashboard/routes/dashboard/settings/SettingsLayout.vue', () => ({
  default: {
    template: '<div><slot name="header" /><slot name="body" /></div>',
  },
}));
vi.mock(
  'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue',
  () => ({ default: { template: '<div><slot name="actions" /></div>' } })
);
vi.mock(
  'dashboard/routes/dashboard/settings/whatsapp/components/NewConnectionDialog.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/routes/dashboard/settings/whatsapp/components/QrDialog.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock(
  'dashboard/routes/dashboard/settings/whatsapp/components/InstanceSettingsDialog.vue',
  () => ({ default: { template: '<div />' } })
);
vi.mock('dashboard/components-next/dialog/Dialog.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/api/inboxes', () => ({
  default: {
    getEvolutionConnectionState: vi.fn(),
    restartEvolution: vi.fn(),
    logoutEvolution: vi.fn(),
  },
}));

const STATES = {
  1: { state: 'open', phone_number: '34600111222', profile_name: 'Ventas' },
  2: { state: 'connecting' },
  3: { state: 'close' },
};

const mountPage = () =>
  mount(WhatsappConnections, {
    global: {
      mocks: { $t: key => key },
      stubs: {
        SettingsLayout: {
          template: '<div><slot name="header" /><slot name="body" /></div>',
        },
        BaseSettingsHeader: {
          template: '<div><slot name="actions" /></div>',
        },
        QrDialog: true,
        InstanceSettingsDialog: true,
        NewConnectionDialog: true,
        Dialog: true,
        Avatar: true,
      },
    },
  });

describe('WhatsApp connections page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.chatwootConfig = { evolutionEnabled: true };
    inboxes.value = [
      {
        id: 1,
        name: 'Ventas',
        channel_type: 'Channel::Api',
        evolution_linked: true,
      },
      {
        id: 2,
        name: 'Soporte',
        channel_type: 'Channel::Api',
        evolution_linked: true,
      },
      {
        id: 3,
        name: 'Avisos',
        channel_type: 'Channel::Api',
        evolution_linked: true,
      },
      { id: 4, name: 'Web', channel_type: 'Channel::WebWidget' },
      {
        id: 5,
        name: 'API sin Evolution',
        channel_type: 'Channel::Api',
        evolution_linked: false,
      },
    ];
    InboxesAPI.getEvolutionConnectionState.mockImplementation(id =>
      STATES[id]
        ? Promise.resolve({ data: STATES[id] })
        : Promise.reject(
            Object.assign(new Error('unreachable'), {
              response: { data: { error: 'unreachable' } },
            })
          )
    );
  });

  it('lists only the inboxes linked to Evolution, with their status', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const cards = wrapper.findAll('article');
    expect(cards).toHaveLength(3);
    expect(cards.map(card => card.find('h3').text())).toEqual([
      'Avisos',
      'Soporte',
      'Ventas',
    ]);
    expect(InboxesAPI.getEvolutionConnectionState).toHaveBeenCalledTimes(3);
    expect(cards[2].text()).toContain('+34600111222 · Ventas');
    expect(cards[2].text()).toContain('WHATSAPP_CONNECTIONS.STATUS.OPEN');
    expect(cards[1].text()).toContain('WHATSAPP_CONNECTIONS.STATUS.CONNECTING');
  });

  it('counts connections by status', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const counts = wrapper.findAll('dd').map(dd => dd.text());
    // Conectadas, esperando, desconectadas, sin respuesta
    expect(counts).toEqual(['1', '1', '1', '0']);
  });

  it('marks an inbox whose Evolution does not answer', async () => {
    inboxes.value = [
      {
        id: 9,
        name: 'Caída',
        channel_type: 'Channel::Api',
        evolution_linked: true,
      },
    ];
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.find('article').text()).toContain(
      'WHATSAPP_CONNECTIONS.STATUS.ERROR'
    );
    expect(wrapper.findAll('dd').map(dd => dd.text())).toEqual([
      '0',
      '0',
      '0',
      '1',
    ]);
  });

  it('restarts a connection and reloads its status', async () => {
    InboxesAPI.restartEvolution.mockResolvedValue({ data: { success: true } });
    const wrapper = mountPage();
    await flushPromises();

    const soporte = wrapper.findAll('article')[1];
    const restartButton = soporte
      .findAll('button')
      .find(
        button =>
          button.attributes('aria-label') ===
          'WHATSAPP_CONNECTIONS.ACTIONS.RESTART'
      );
    await restartButton.trigger('click');
    await flushPromises();

    expect(InboxesAPI.restartEvolution).toHaveBeenCalledWith(2);
    expect(InboxesAPI.getEvolutionConnectionState).toHaveBeenCalledTimes(4);
  });

  it('shows the empty state when nothing is linked yet', async () => {
    inboxes.value = [];
    const wrapper = mountPage();
    await flushPromises();

    expect(wrapper.text()).toContain('WHATSAPP_CONNECTIONS.EMPTY.TITLE');
    expect(wrapper.findAll('article')).toHaveLength(0);
  });
});
