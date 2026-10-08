import { mount, flushPromises } from '@vue/test-utils';
import InboxesAPI from 'dashboard/api/inboxes';
import EvolutionConnection from '../EvolutionConnection.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/inboxes', () => ({
  default: {
    getEvolutionConnectionState: vi.fn(),
    connectEvolution: vi.fn(),
    logoutEvolution: vi.fn(),
  },
}));

const QR = 'data:image/png;base64,AAA';

const mountComponent = (props = {}) =>
  mount(EvolutionConnection, {
    props: { inboxId: 7, ...props },
    global: {
      mocks: { $t: key => key },
      stubs: { Avatar: true, Spinner: true },
    },
  });

describe('EvolutionConnection', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('shows the linked number when the session is open', async () => {
    InboxesAPI.getEvolutionConnectionState.mockResolvedValue({
      data: {
        state: 'open',
        phone_number: '34600111222',
        profile_name: 'Soporte',
      },
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.OPEN'
    );
    expect(wrapper.text()).toContain('+34600111222');
    expect(wrapper.find('img').exists()).toBe(false);
    expect(InboxesAPI.connectEvolution).not.toHaveBeenCalled();
  });

  it('offers to connect without requesting a QR when disconnected', async () => {
    InboxesAPI.getEvolutionConnectionState.mockResolvedValue({
      data: { state: 'close' },
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.CLOSE'
    );
    expect(InboxesAPI.connectEvolution).not.toHaveBeenCalled();
  });

  it('shows the QR and switches to connected once the phone scans it', async () => {
    InboxesAPI.getEvolutionConnectionState.mockResolvedValueOnce({
      data: { state: 'close' },
    });
    InboxesAPI.connectEvolution.mockResolvedValue({
      data: { state: 'connecting', qr_code: QR },
    });

    const wrapper = mountComponent({ autoConnect: true });
    await flushPromises();

    expect(wrapper.find('img').attributes('src')).toBe(QR);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.CONNECTING'
    );

    InboxesAPI.getEvolutionConnectionState.mockResolvedValue({
      data: { state: 'open', phone_number: '34600111222' },
    });
    await vi.advanceTimersByTimeAsync(3000);
    await flushPromises();

    expect(wrapper.find('img').exists()).toBe(false);
    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.OPEN'
    );
    expect(wrapper.emitted('connected')).toHaveLength(1);
  });

  it('stops polling and marks the QR expired when nobody scans it', async () => {
    InboxesAPI.getEvolutionConnectionState.mockResolvedValue({
      data: { state: 'connecting' },
    });
    InboxesAPI.connectEvolution.mockResolvedValue({
      data: { state: 'connecting', qr_code: QR },
    });

    const wrapper = mountComponent();
    await flushPromises();
    expect(wrapper.find('img').exists()).toBe(true);

    await vi.advanceTimersByTimeAsync(3 * 60 * 1000);
    await flushPromises();
    const callsAtExpiry = InboxesAPI.connectEvolution.mock.calls.length;

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.STATUS.EXPIRED'
    );
    expect(wrapper.find('img').exists()).toBe(false);

    await vi.advanceTimersByTimeAsync(60 * 1000);
    expect(InboxesAPI.connectEvolution.mock.calls.length).toBe(callsAtExpiry);
  });

  it('shows the error when Evolution cannot be reached', async () => {
    InboxesAPI.getEvolutionConnectionState.mockRejectedValue({
      response: { data: { error: 'unreachable' } },
    });

    const wrapper = mountComponent();
    await flushPromises();

    expect(wrapper.text()).toContain(
      'INBOX_MGMT.EVOLUTION_CONNECTION.ERRORS.UNREACHABLE'
    );
  });
});
