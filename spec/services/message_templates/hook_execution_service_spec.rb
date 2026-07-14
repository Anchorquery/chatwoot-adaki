require 'rails_helper'

describe MessageTemplates::HookExecutionService do
  context 'when there is no incoming message in conversation' do
    it 'will not call any hooks' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact)
      # ensure greeting hook is enabled
      conversation.inbox.update(greeting_enabled: true, enable_email_collect: true)

      email_collect_service = double

      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::Greeting).to receive(:new)

      # described class gets called in message after commit
      create(:message, conversation: conversation, account: conversation.account, message_type: 'activity', content: 'Conversation marked resolved!!')

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new)
    end
  end

  context 'when Greeting Message' do
    it 'doesnot calls ::MessageTemplates::Template::Greeting if greeting_message is empty' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact)
      # ensure greeting hook is enabled
      conversation.inbox.update(greeting_enabled: true, enable_email_collect: true)

      email_collect_service = double

      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::Greeting).to receive(:new)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
      expect(MessageTemplates::Template::EmailCollect).to have_received(:new).with(conversation: message.conversation)
      expect(email_collect_service).to have_received(:perform)
    end

    it 'will not call ::MessageTemplates::Template::Greeting if its a tweet conversation' do
      twitter_channel = create(:channel_twitter_profile)
      twitter_inbox = create(:inbox, channel: twitter_channel)
      # ensure greeting hook is enabled and greeting_message is present
      twitter_inbox.update(greeting_enabled: true, greeting_message: 'Hi, this is a greeting message')

      conversation = create(:conversation, inbox: twitter_inbox, additional_attributes: { type: 'tweet' })
      greeting_service = double
      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)

      message = create(:message, conversation: conversation, account: conversation.account)
      expect(MessageTemplates::Template::Greeting).not_to have_received(:new).with(conversation: message.conversation)
    end
  end

  context 'when it is a first message from web widget' do
    it 'calls ::MessageTemplates::Template::EmailCollect' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact)

      # ensure greeting hook is enabled and greeting_message is present
      conversation.inbox.update(greeting_enabled: true, enable_email_collect: true, greeting_message: 'Hi, this is a greeting message')

      email_collect_service = double
      greeting_service = double
      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::Greeting).to have_received(:new).with(conversation: message.conversation)
      expect(greeting_service).to have_received(:perform)
      expect(MessageTemplates::Template::EmailCollect).to have_received(:new).with(conversation: message.conversation)
      expect(email_collect_service).to have_received(:perform)
    end

    it 'doesnot calls ::MessageTemplates::Template::EmailCollect on campaign conversations' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact, campaign: create(:campaign))

      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(true)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new).with(conversation: message.conversation)
    end

    it 'doesnot calls ::MessageTemplates::Template::EmailCollect when enable_email_collect form is disabled' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact)

      conversation.inbox.update(enable_email_collect: false)
      # ensure prechat form is enabled
      conversation.inbox.channel.update(pre_chat_form_enabled: true)
      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(true)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new).with(conversation: message.conversation)
    end
  end

  context 'when conversation has a campaign' do
    let(:campaign) { create(:campaign) }

    it 'does not call ::MessageTemplates::Template::Greeting on campaign conversations' do
      contact = create(:contact, email: nil)
      conversation = create(:conversation, contact: contact, campaign: campaign)
      conversation.inbox.update(greeting_enabled: true, greeting_message: 'Hi, this is a greeting message', enable_email_collect: false)

      greeting_service = double
      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)

      create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
    end

    it 'does not call ::MessageTemplates::Template::OutOfOffice on campaign conversations' do
      contact = create(:contact)
      conversation = create(:conversation, contact: contact, campaign: campaign)

      conversation.inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')
      conversation.inbox.working_hours.today.update!(closed_all_day: true)

      out_of_office_service = double
      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)

      create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
    end
  end

  context 'when message is an auto reply email' do
    it 'does not call any template hooks' do
      contact = create(:contact)
      conversation = create(:conversation, contact: contact)
      conversation.inbox.update(greeting_enabled: true, enable_email_collect: true, greeting_message: 'Hi, this is a greeting message')

      message = create(:message, conversation: conversation, account: conversation.account, content_type: :incoming_email)
      message.content_attributes = { email: { auto_reply: true } }
      message.save!

      greeting_service = double
      email_collect_service = double
      out_of_office_service = double

      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)

      described_class.new(message: message).perform

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new)
      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
    end
  end

  context 'when it is after working hours' do
    it 'calls ::MessageTemplates::Template::OutOfOffice' do
      contact = create(:contact)
      conversation = create(:conversation, contact: contact)

      conversation.inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')
      conversation.inbox.working_hours.today.update!(closed_all_day: true)

      out_of_office_service = double

      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account)

      expect(MessageTemplates::Template::OutOfOffice).to have_received(:new).with(conversation: message.conversation)
      expect(out_of_office_service).to have_received(:perform)
    end

    context 'with recent outgoing messages' do
      it 'does not call ::MessageTemplates::Template::OutOfOffice when there are recent outgoing messages' do
        contact = create(:contact)
        conversation = create(:conversation, contact: contact)

        conversation.inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')
        conversation.inbox.working_hours.today.update!(closed_all_day: true)

        create(:message, conversation: conversation, account: conversation.account, message_type: :outgoing, created_at: 2.minutes.ago)

        out_of_office_service = double
        allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
        allow(out_of_office_service).to receive(:perform).and_return(true)

        create(:message, conversation: conversation, account: conversation.account)

        expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
        expect(out_of_office_service).not_to have_received(:perform)
      end

      it 'ignores private note and calls ::MessageTemplates::Template::OutOfOffice' do
        contact = create(:contact)
        conversation = create(:conversation, contact: contact)

        conversation.inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')
        conversation.inbox.working_hours.today.update!(closed_all_day: true)

        create(:message, conversation: conversation, account: conversation.account, private: true, message_type: :outgoing, created_at: 2.minutes.ago)

        out_of_office_service = double
        allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
        allow(out_of_office_service).to receive(:perform).and_return(true)

        create(:message, conversation: conversation, account: conversation.account)

        expect(MessageTemplates::Template::OutOfOffice).to have_received(:new).with(conversation: conversation)
        expect(out_of_office_service).to have_received(:perform)
      end
    end

    it 'will not calls ::MessageTemplates::Template::OutOfOffice when outgoing message' do
      contact = create(:contact)
      conversation = create(:conversation, contact: contact)

      conversation.inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')
      conversation.inbox.working_hours.today.update!(closed_all_day: true)

      out_of_office_service = double

      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)

      # described class gets called in message after commit
      message = create(:message, conversation: conversation, account: conversation.account, message_type: 'outgoing')

      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new).with(conversation: message.conversation)
      expect(out_of_office_service).not_to have_received(:perform)
    end

    it 'will not call ::MessageTemplates::Template::OutOfOffice if its a tweet conversation' do
      twitter_channel = create(:channel_twitter_profile)
      twitter_inbox = create(:inbox, channel: twitter_channel)
      twitter_inbox.update(working_hours_enabled: true, out_of_office_message: 'We are out of office')

      conversation = create(:conversation, inbox: twitter_inbox, additional_attributes: { type: 'tweet' })

      out_of_office_service = double

      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(false)

      message = create(:message, conversation: conversation, account: conversation.account)
      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new).with(conversation: message.conversation)
      expect(out_of_office_service).not_to receive(:perform)
    end
  end

  context 'when conversation is a group chat' do
    let(:contact) { create(:contact) }
    let(:conversation) { create(:conversation, contact: contact) }
    let(:greeting_service) { double }
    let(:email_collect_service) { double }
    let(:out_of_office_service) { double }

    before do
      # Simulating a group chat via Evolution API source_id format
      conversation.contact_inbox.update!(source_id: '12345-67890@g.us')
      conversation.inbox.update(greeting_enabled: true, enable_email_collect: true, greeting_message: 'Hi, this is a greeting message')

      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::EmailCollect).to receive(:new).and_return(email_collect_service)
      allow(email_collect_service).to receive(:perform).and_return(true)
      allow(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office_service)
      allow(out_of_office_service).to receive(:perform).and_return(true)
    end

    it 'does not call any template hooks when the bot is not mentioned' do
      create(:message, conversation: conversation, account: conversation.account, content: 'Hello everyone!')

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
      expect(MessageTemplates::Template::EmailCollect).not_to have_received(:new)
      expect(MessageTemplates::Template::OutOfOffice).not_to have_received(:new)
    end

    it 'calls template hooks when the bot is mentioned' do
      allow_any_instance_of(Conversation).to receive(:bot_mentioned?).and_return(true)

      # Clean up Redis rate limit key first to ensure a clean state
      Redis::Alfred.delete("rate_limit:group_chat:#{conversation.id}:user:#{contact.id}")

      create(:message, conversation: conversation, account: conversation.account, sender: contact, content: '!bot tell me a joke')

      expect(MessageTemplates::Template::Greeting).to have_received(:new)
    end

    it 'triggers cooldown warning and blocks hooks when user exceeds the rate limit' do
      allow_any_instance_of(Conversation).to receive(:bot_mentioned?).and_return(true)

      redis_key = "rate_limit:group_chat:#{conversation.id}:user:#{contact.id}"
      Redis::Alfred.delete(redis_key)

      # Simulate 3 previous requests to trigger rate limit on the 4th
      Redis::Alfred.set(redis_key, 3)

      create(:message, conversation: conversation, account: conversation.account, sender: contact, content: '!bot tell me a joke')

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
      expect(conversation.messages.outgoing.last.content).to include('⚠️ Por favor, evita el spam.')
    end
  end

  context 'when conversation is a whatsapp channel (newsletter)' do
    let(:contact) { create(:contact) }
    let(:conversation) { create(:conversation, contact: contact) }
    let(:greeting_service) { double }

    before do
      # Simulating a WhatsApp channel conversation via Evolution API source_id format
      conversation.contact_inbox.update!(source_id: '120363000000000000@newsletter')
      conversation.inbox.update(greeting_enabled: true, greeting_message: 'Hi, this is a greeting message')

      allow(MessageTemplates::Template::Greeting).to receive(:new).and_return(greeting_service)
      allow(greeting_service).to receive(:perform).and_return(true)
    end

    it 'does not call any template hooks when the bot is not mentioned' do
      create(:message, conversation: conversation, account: conversation.account, content: 'Hello everyone!')

      expect(MessageTemplates::Template::Greeting).not_to have_received(:new)
    end

    it 'calls template hooks when the bot is mentioned' do
      allow_any_instance_of(Conversation).to receive(:bot_mentioned?).and_return(true)

      Redis::Alfred.delete("rate_limit:channel_chat:#{conversation.id}:user:#{contact.id}")

      create(:message, conversation: conversation, account: conversation.account, sender: contact, content: '!bot tell me a joke')

      expect(MessageTemplates::Template::Greeting).to have_received(:new)
    end
  end
end
