import { mount, flushPromises } from '@vue/test-utils';
import InboxesAPI from 'dashboard/api/inboxes';
import { useAlert } from 'dashboard/composables';
import EvolutionContactPrivacy from '../EvolutionContactPrivacy.vue';

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/inboxes', () => ({
  default: {
    getEvolutionPrivacyContact: vi.fn(),
    updateEvolutionPrivacyContact: vi.fn(),
  },
}));

const open = vi.fn();
const close = vi.fn();

// Dialog real usa <dialog> y Teleport; aquí basta con exponer open/close y
// dejar disparar el evento confirm.
const DialogStub = {
  emits: ['confirm'],
  setup(_, { expose }) {
    expose({ open, close });
  },
  template: '<div class="dialog-stub" @click="$emit(\'confirm\')" />',
};

const mountCard = () =>
  mount(EvolutionContactPrivacy, {
    props: { inboxId: 7, contactId: 42 },
    global: {
      mocks: { $t: key => key },
      stubs: { Dialog: DialogStub, Spinner: true, RouterLink: true },
    },
  });

const buttonLabelled = (wrapper, label) =>
  wrapper
    .findAll('button')
    .find(button => button.attributes('label') === label);

describe('EvolutionContactPrivacy', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    InboxesAPI.getEvolutionPrivacyContact.mockResolvedValue({
      data: { filtered: false, mode: 'block' },
    });
  });

  it('asks for confirmation before filtering the chat', async () => {
    InboxesAPI.updateEvolutionPrivacyContact.mockResolvedValue({ data: {} });
    const wrapper = mountCard();
    await flushPromises();

    expect(wrapper.text()).toContain('PRIVACY_FILTER.CONTACT.RECEIVING');
    await buttonLabelled(wrapper, 'PRIVACY_FILTER.CONTACT.EXCLUDE').trigger(
      'click'
    );
    expect(open).toHaveBeenCalled();
    expect(InboxesAPI.updateEvolutionPrivacyContact).not.toHaveBeenCalled();

    await wrapper.find('.dialog-stub').trigger('click');
    await flushPromises();

    expect(InboxesAPI.updateEvolutionPrivacyContact).toHaveBeenCalledWith(
      7,
      42,
      true
    );
    expect(wrapper.text()).toContain('PRIVACY_FILTER.CONTACT.FILTERED');
  });

  it('explains why the last allowed chat cannot be removed', async () => {
    InboxesAPI.updateEvolutionPrivacyContact.mockRejectedValue(
      Object.assign(new Error('rejected'), {
        response: { data: { message: 'last_allowed' } },
      })
    );
    const wrapper = mountCard();
    await flushPromises();

    await wrapper.find('.dialog-stub').trigger('click');
    await flushPromises();

    expect(useAlert).toHaveBeenCalledWith(
      'PRIVACY_FILTER.CONTACT.ERRORS.LAST_ALLOWED'
    );
    expect(wrapper.text()).toContain('PRIVACY_FILTER.CONTACT.RECEIVING');
  });
});
