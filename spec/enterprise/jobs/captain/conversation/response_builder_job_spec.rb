require 'rails_helper'

RSpec.describe Captain::Conversation::ResponseBuilderJob, type: :job do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:captain_inbox_association) { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }

  it 'runs on the dedicated captain Sidekiq capsule, not :default' do
    expect(described_class.queue_name).to eq('captain')
  end

  describe '#perform' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }
    let(:mock_agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }
    let(:mock_action_classifier_service) { instance_double(Captain::Llm::AssistantActionClassifierService) }

    before do
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)

      allow(inbox).to receive(:captain_active?).and_return(true)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'Hey, welcome to Captain Specs' })
      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(mock_agent_runner_service)
      allow(mock_agent_runner_service).to receive(:generate_response).and_return({ 'response' => 'Hey, welcome to Captain V2' })
      allow(Captain::Llm::AssistantActionClassifierService).to receive(:new).and_return(mock_action_classifier_service)
      allow(mock_action_classifier_service).to receive(:classify).and_return({ 'action' => 'continue' })
    end

    context 'when captain_v2 is disabled' do
      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
      end

      it 'uses Captain::Llm::AssistantChatService' do
        expect(Captain::Llm::AssistantChatService).to receive(:new).with(assistant: assistant, conversation: conversation)
        expect(Captain::Assistant::AgentRunnerService).not_to receive(:new)

        described_class.perform_now(conversation, assistant)
        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain Specs')
      end

      it 'generates and processes response' do
        described_class.perform_now(conversation, assistant)
        expect(conversation.messages.count).to eq(2)
        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain Specs')
      end

      it 'generates and processes response for open conversations' do
        conversation.update!(status: :open)

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.count).to eq(2)
        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain Specs')
      end

      it 'does not generate a response for open conversations after a human agent has replied' do
        agent = create(:user, account: account)
        conversation.update!(status: :open)
        create(:message, conversation: conversation, message_type: :outgoing, account: account, sender: agent)

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.where(sender_type: 'Captain::Assistant')).to be_empty
      end

      it 'does not generate a response for conversations assigned to a human agent' do
        agent = create(:user, account: account)
        conversation.update!(assignee: agent)

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.where(sender_type: 'Captain::Assistant')).to be_empty
      end

      it 'increments usage response' do
        described_class.perform_now(conversation, assistant)
        account.reload
        expect(account.usage_limits[:captain][:responses][:consumed]).to eq(1)
      end

      it 'does not run the action classifier when the classifier feature is disabled' do
        expect(Captain::Llm::AssistantActionClassifierService).not_to receive(:new)

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain Specs')
      end

      context 'when V1 action classifier is enabled' do
        before do
          allow(account).to receive(:feature_enabled?).and_return(false)
          allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
          allow(account).to receive(:feature_enabled?).with('captain_v1_action_classifier').and_return(true)
        end

        it 'keeps the conversation pending when the classifier returns continue' do
          expect(Captain::Llm::AssistantActionClassifierService).to receive(:new).with(
            assistant: assistant,
            conversation: conversation
          ).and_return(mock_action_classifier_service)
          expect(mock_action_classifier_service).to receive(:classify).with(
            message_history: [{ content: 'Hello', role: 'user' }],
            assistant_response: 'Hey, welcome to Captain Specs'
          ).and_return({
                         'action' => 'continue',
                         'action_reason' => 'general_product_question',
                         'model' => 'gpt-4.1'
                       })

          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('pending')
          expect(conversation.messages.outgoing.last.content).to eq('Hey, welcome to Captain Specs')
          expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(1)
        end

        it 'hands off without incrementing response usage when the classifier returns handoff' do
          allow(mock_action_classifier_service).to receive(:classify).and_return({
                                                                                   'action' => 'handoff',
                                                                                   'action_reason' => 'explicit_human_request',
                                                                                   'model' => 'gpt-4.1'
                                                                                 })

          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('open')
          expect(conversation.messages.outgoing.last.content).to eq(I18n.t('conversations.captain.handoff'))
          expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
        end

        it 'skips the classifier when the legacy handoff token is returned' do
          allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
          expect(Captain::Llm::AssistantActionClassifierService).not_to receive(:new)

          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('open')
          expect(conversation.messages.outgoing.last.content).to eq(I18n.t('conversations.captain.handoff'))
        end

        it 'falls back to the assistant response when the classifier fails' do
          error = StandardError.new('classifier unavailable')
          allow(mock_action_classifier_service).to receive(:classify).and_raise(error)
          allow(ChatwootExceptionTracker).to receive(:new).and_call_original

          described_class.perform_now(conversation, assistant)

          expect(ChatwootExceptionTracker).to have_received(:new).with(error, account: account)
          expect(conversation.reload.status).to eq('pending')
          expect(conversation.messages.outgoing.last.content).to eq('Hey, welcome to Captain Specs')
          expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(1)
        end

        it 'falls back to the assistant response when the classifier returns an invalid action' do
          allow(mock_action_classifier_service).to receive(:classify).and_return({
                                                                                   'action' => nil,
                                                                                   'error' => 'invalid_classifier_response'
                                                                                 })

          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('pending')
          expect(conversation.messages.outgoing.last.content).to eq('Hey, welcome to Captain Specs')
          expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(1)
        end

        it 'skips the classifier when a human takes over during response generation' do
          agent = create(:user, account: account)
          allow(mock_llm_chat_service).to receive(:generate_response) do
            conversation.update!(assignee: agent)
            { 'response' => 'Hey, welcome to Captain Specs' }
          end

          expect(Captain::Llm::AssistantActionClassifierService).not_to receive(:new)

          described_class.perform_now(conversation, assistant)

          expect(conversation.messages.outgoing.count).to eq(0)
          expect(account.reload.usage_limits[:captain][:responses][:consumed]).to eq(0)
        end
      end

      it 'does not send a response when assigned to a human agent' do
        agent = create(:user, account: account)
        conversation.update!(assignee: agent)

        expect(mock_llm_chat_service).not_to receive(:generate_response)
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.outgoing.count })
      end
    end

    context 'when captain_v2 is enabled' do
      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(true)
      end

      it 'uses Captain::Assistant::AgentRunnerService' do
        expect(Captain::Assistant::AgentRunnerService).to receive(:new).with(
          assistant: assistant,
          conversation: conversation
        )
        expect(Captain::Llm::AssistantChatService).not_to receive(:new)

        described_class.perform_now(conversation, assistant)
        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
      end

      it 'passes message history to agent runner service' do
        expected_messages = [
          { content: 'Hello', role: 'user' }
        ]

        expect(mock_agent_runner_service).to receive(:generate_response).with(
          message_history: expected_messages
        )

        described_class.perform_now(conversation, assistant)
      end

      it 'generates and processes response' do
        described_class.perform_now(conversation, assistant)
        expect(conversation.messages.count).to eq(2)
        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.last.content).to eq('Hey, welcome to Captain V2')
      end

      it 'increments usage response' do
        described_class.perform_now(conversation, assistant)
        account.reload
        expect(account.usage_limits[:captain][:responses][:consumed]).to eq(1)
      end

      context 'when the inbox is a WhatsApp bridge on a Channel::Api inbox' do
        let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }

        before do
          allow(mock_agent_runner_service).to receive(:generate_response).and_return(
            { 'response' => "### Tarjetas NFC\n* **1 Tarjeta:** 18,90 €\n[https://x.io/p](https://x.io/p)" }
          )
        end

        it 'flattens Markdown the phone cannot render before saving the reply' do
          described_class.perform_now(conversation, assistant)

          expect(conversation.messages.last.content).to eq("**Tarjetas NFC**\n* **1 Tarjeta:** 18,90 €\nhttps://x.io/p")
        end

        it 'flattens the handoff message too' do
          assistant.update!(config: assistant.config.merge('handoff_message' => "## Un momento\n[web](https://x.io)"))
          allow(mock_agent_runner_service).to receive(:generate_response).and_return(
            { 'response' => 'conversation_handoff', 'handoff_tool_called' => true }
          )
          conversation.update!(status: :open)

          described_class.perform_now(conversation, assistant)

          expect(conversation.messages.last.content).to eq("**Un momento**\nweb (https://x.io)")
        end
      end

      context 'when a newer incoming message arrived after this job was enqueued (message burst)' do
        it 'stands down and lets the newer message\'s job answer the whole burst' do
          job = described_class.new(conversation, assistant)
          job.enqueued_at = Time.current
          create(:message, conversation: conversation, content: 'y otra cosa', message_type: :incoming, created_at: 1.second.from_now)

          job.perform_now

          expect(conversation.messages.outgoing.count).to eq(0)
          expect(mock_agent_runner_service).not_to have_received(:generate_response)
        end

        it 'still answers when the only newer messages are outgoing or private' do
          job = described_class.new(conversation, assistant)
          job.enqueued_at = Time.current
          create(:message, conversation: conversation, content: 'nota', message_type: :incoming, private: true, created_at: 1.second.from_now)

          job.perform_now

          expect(conversation.messages.outgoing.where(private: false).count).to eq(1)
        end
      end

      context 'when another Captain run already holds the conversation lock' do
        let(:lock_key) { "captain:conversation:#{conversation.id}" }

        it 'does not answer twice and re-enqueues itself to answer right after the run in progress' do
          Redis::LockManager.new.lock(lock_key, 60)

          expect { described_class.perform_now(conversation, assistant) }
            .to have_enqueued_job(described_class).with(conversation, assistant, lock_attempt: 1)
          expect(conversation.messages.outgoing.count).to eq(0)
        ensure
          Redis::LockManager.new.unlock(lock_key)
        end

        it 'gives up (and reports) instead of re-enqueuing forever' do
          Redis::LockManager.new.lock(lock_key, 60)
          allow(ChatwootExceptionTracker).to receive(:new).and_return(instance_double(ChatwootExceptionTracker,
                                                                                      capture_exception: true))

          expect { described_class.perform_now(conversation, assistant, lock_attempt: described_class::MAX_LOCK_ATTEMPTS) }
            .not_to have_enqueued_job(described_class)
          expect(ChatwootExceptionTracker).to have_received(:new)
        ensure
          Redis::LockManager.new.unlock(lock_key)
        end

        it 'releases the lock once the run finishes, so the next message is answered' do
          described_class.perform_now(conversation, assistant)

          expect(Redis::LockManager.new.locked?(lock_key)).to be(false)
          expect(conversation.messages.outgoing.count).to eq(1)
        end
      end

      context 'when the inbox renders Markdown itself (web widget)' do
        before do
          allow(mock_agent_runner_service).to receive(:generate_response).and_return({ 'response' => "### Título\n[web](https://x.io)" })
        end

        it 'leaves the reply untouched' do
          described_class.perform_now(conversation, assistant)

          expect(conversation.messages.last.content).to eq("### Título\n[web](https://x.io)")
        end
      end
    end

    context 'when captain_v2 handoff tool fires during agent execution' do
      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(true)
      end

      it 'creates a public handoff message visible to the customer' do
        allow(mock_agent_runner_service).to receive(:generate_response) do
          conversation.update!(status: :open)
          { 'response' => 'Let me connect you', 'handoff_tool_called' => true }
        end

        described_class.perform_now(conversation, assistant)

        public_messages = conversation.messages.outgoing.where(private: false)
        expect(public_messages.count).to eq(1)
        expect(public_messages.last.content).to eq(I18n.t('conversations.captain.handoff'))
      end

      it 'does not call bot_handoff! again when conversation is already open' do
        allow(mock_agent_runner_service).to receive(:generate_response) do
          conversation.update!(status: :open)
          { 'response' => 'Let me connect you', 'handoff_tool_called' => true }
        end

        expect(conversation).not_to receive(:bot_handoff!)

        described_class.perform_now(conversation, assistant)
      end

      it 'does not create a duplicate out of office message' do
        allow(mock_agent_runner_service).to receive(:generate_response) do
          conversation.update!(status: :open)
          { 'response' => 'Let me connect you', 'handoff_tool_called' => true }
        end

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.template.count).to eq(0)
      end

      it 'preserves waiting_since when HandoffTool already called bot_handoff!' do
        original_waiting_since = 5.minutes.ago
        conversation.update!(waiting_since: original_waiting_since)

        allow(mock_agent_runner_service).to receive(:generate_response) do
          conversation.update!(status: :open, waiting_since: original_waiting_since)
          { 'response' => 'Let me connect you', 'handoff_tool_called' => true }
        end

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.waiting_since).to be_within(1.second).of(original_waiting_since)
      end

      it 'does not hand off when handoff_tool_called is false' do
        allow(mock_agent_runner_service).to receive(:generate_response).and_return({
                                                                                     'response' => 'Hi! How can I help you?',
                                                                                     'handoff_tool_called' => false
                                                                                   })

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.last.content).to eq('Hi! How can I help you?')
        expect(conversation.reload.status).to eq('pending')
      end

      it 'falls back to a full V1 handoff when HandoffTool fired but failed to commit' do
        allow(mock_agent_runner_service).to receive(:generate_response).and_return({
                                                                                     'response' => 'I tried to hand off',
                                                                                     'handoff_tool_called' => true
                                                                                   })

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.status).to eq('open')
        public_messages = conversation.messages.outgoing.where(private: false)
        expect(public_messages.count).to eq(1)
        expect(public_messages.last.content).to eq(I18n.t('conversations.captain.handoff'))
      end
    end

    # Regression (PR #13417): wrapping create_handoff_message and bot_handoff! in the
    # same transaction defers the message's after_create_commit until commit, at which
    # point it clears waiting_since (bot_response). The handoff path must stay outside
    # the transaction so the callback fires before bot_handoff! sets waiting_since.
    context 'when handoff is requested' do
      let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
        allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'sets waiting_since to approximately the handoff time' do
        # Don't use freeze_time here: we need a real gap between the seeded waiting_since
        # and Time.current, otherwise "preserved" and "reset" both look identical.
        conversation.update!(waiting_since: 10.minutes.ago)

        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.status).to eq('open')
        expect(conversation.waiting_since).to be_within(5.seconds).of(Time.current)
      end

      it 'preserves waiting_since so a human reply consumes it for reply_time tracking' do
        described_class.perform_now(conversation, assistant)

        conversation.reload
        expect(conversation.waiting_since).to be_present

        # A human reply clears waiting_since (consumed by dispatch_create_events
        # to emit FIRST_REPLY_CREATED or REPLY_CREATED for reply_time tracking).
        create(:message, conversation: conversation, message_type: :outgoing,
                         sender: agent, account: account, inbox: inbox)
        expect(conversation.reload.waiting_since).to be_nil
      end
    end

    context 'when message contains an image' do
      let(:message_with_image) { create(:message, conversation: conversation, message_type: :incoming, content: 'Can you help with this error?') }
      let(:image_attachment) { message_with_image.attachments.create!(account: account, file_type: :image, external_url: 'https://example.com/error.jpg') }

      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
        image_attachment
      end

      it 'includes image URL directly in the message content for OpenAI vision analysis' do
        # Expect the generate_response to receive multimodal content with image URL
        expect(mock_llm_chat_service).to receive(:generate_response) do |**kwargs|
          history = kwargs[:message_history]
          last_entry = history.last
          expect(last_entry[:content]).to be_an(Array)
          expect(last_entry[:content].any? { |part| part[:type] == 'text' && part[:text] == 'Can you help with this error?' }).to be true
          expect(last_entry[:content].any? do |part|
            part[:type] == 'image_url' && part[:image_url][:url] == 'https://example.com/error.jpg'
          end).to be true
          { 'response' => 'I can see the error in your image. It appears to be a database connection issue.' }
        end

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'retry mechanisms for image processing' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }
    let(:mock_message_builder) { instance_double(Captain::OpenAiMessageBuilderService) }

    before do
      allow(account).to receive(:feature_enabled?).and_return(false)
      allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
      create(:message, conversation: conversation, content: 'Hello with image', message_type: :incoming)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      allow(Captain::OpenAiMessageBuilderService).to receive(:new).with(message: anything).and_return(mock_message_builder)
      allow(mock_message_builder).to receive(:generate_content).and_return('Hello with image')
      allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'Test response' })
    end

    context 'when ActiveStorage::FileNotFoundError occurs' do
      it 'handles file errors and triggers handoff' do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image file not found')

        # For retryable errors, the job should handle them and proceed with handoff
        described_class.perform_now(conversation, assistant)

        # Verify handoff occurred due to repeated failures
        expect(conversation.reload.status).to eq('open')
      end

      it 'succeeds when no error occurs' do
        # Don't raise any error, should succeed normally
        allow(mock_message_builder).to receive(:generate_content)
          .and_return('Image content processed successfully')

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.count).to eq(1)
        expect(conversation.messages.outgoing.last.content).to eq('Test response')
      end
    end

    context 'when Faraday::BadRequestError occurs' do
      it 'handles API errors and triggers handoff' do
        allow(mock_llm_chat_service).to receive(:generate_response)
          .and_raise(Faraday::BadRequestError, 'Bad request to image service')
        allow(Rails.logger).to receive(:info).and_call_original

        described_class.perform_now(conversation, assistant)
        expect(conversation.reload.status).to eq('open')
        expect(Rails.logger).to have_received(:info).with(include('source=error reason=faraday_bad_request_error'))
      end

      it 'succeeds when no error occurs' do
        # Don't raise any error, should succeed normally
        allow(mock_llm_chat_service).to receive(:generate_response)
          .and_return({ 'response' => 'Response after retry' })

        described_class.perform_now(conversation, assistant)

        expect(conversation.messages.outgoing.last.content).to eq('Response after retry')
      end
    end

    context 'when image processing fails permanently' do
      before do
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(ActiveStorage::FileNotFoundError, 'Image permanently unavailable')
      end

      it 'triggers handoff after max retries' do
        # Since perform_now re-raises retryable errors, simulate the final failure after retries
        allow(mock_message_builder).to receive(:generate_content)
          .and_raise(StandardError, 'Max retries exceeded')

        expect(ChatwootExceptionTracker).to receive(:new).and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when non-retryable error occurs' do
      let(:standard_error) { StandardError.new('Generic error') }

      before do
        allow(mock_llm_chat_service).to receive(:generate_response).and_raise(standard_error)
      end

      it 'handles error and triggers handoff' do
        expect(ChatwootExceptionTracker).to receive(:new)
          .with(standard_error, account: account)
          .and_call_original

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'ensures Current.executed_by is reset' do
        expect(Current).to receive(:executed_by=).with(assistant)
        expect(Current).to receive(:executed_by=).with(nil)

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'job configuration' do
    it 'has retry_on configuration for retryable errors' do
      expect(described_class).to respond_to(:retry_on)
    end
  end

  # Captain::FailurePolicy classification — see docs/adaki/captain-remediacion.md
  # §2a. Unit coverage of the classification logic itself lives in
  # spec/enterprise/lib/captain/failure_policy_spec.rb; this covers how the job
  # reacts once a failure is classified, for both runtimes.
  describe 'failure classification' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }

    before do
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
    end

    context 'with V1 (Captain::Llm::AssistantChatService raises directly)' do
      let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }

      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
        allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      end

      context 'when the LLM call fails with a transient provider error' do
        before do
          allow(mock_llm_chat_service).to receive(:generate_response).and_raise(RubyLLM::ServerError.new('server error'))
        end

        it 'does not hand off — it is retried at the job level instead (see retry_on above)' do
          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('pending')
          expect(conversation.messages.outgoing).to be_empty
        end
      end

      context 'when the LLM call fails with a dead/revoked credential' do
        before do
          allow(mock_llm_chat_service).to receive(:generate_response)
            .and_raise(RubyLLM::UnauthorizedError.new('Incorrect API key provided'))
        end

        it 'hands off and leaves a private note distinguishing it from a legitimate escalation' do
          described_class.perform_now(conversation, assistant)
          conversation.reload

          expect(conversation.status).to eq('open')

          note = conversation.messages.where(private: true).last
          expect(note.content).to include('configuration', 'Incorrect API key provided')

          public_message = conversation.messages.outgoing.where(private: false).last
          expect(public_message.content).to eq(I18n.t('conversations.captain.handoff'))
        end

        it 'writes the note after the handoff so it can @mention the handoff team (with the cause) for notification' do
          team = create(:team, account: account, name: 'Soporte')
          create(:captain_inbox, inbox: inbox, captain_assistant: assistant, settings: { 'handoff_team_id' => team.id })

          described_class.perform_now(conversation, assistant)

          note = conversation.reload.messages.where(private: true).last
          expect(note.content).to start_with("[@#{team.name}](mention://team/#{team.id}/#{team.name})")
          expect(note.content).to include('Incorrect API key provided')
          expect(conversation.team).to eq(team)
        end
      end

      context 'when the Adaki monthly limit is exceeded' do
        before do
          allow(mock_llm_chat_service).to receive(:generate_response)
            .and_raise(Adaki::CaptainUsageTracker::LimitExceeded.new('limit reached'))
        end

        it 'hands off and leaves a private note' do
          described_class.perform_now(conversation, assistant)
          conversation.reload

          expect(conversation.status).to eq('open')
          expect(conversation.messages.where(private: true).last.content).to include('limit_adaki')
        end
      end
    end

    context 'with V2 (Captain::Assistant::AgentRunnerService reports failure_class in its response)' do
      let(:mock_agent_runner_service) { instance_double(Captain::Assistant::AgentRunnerService) }

      before do
        allow(account).to receive(:feature_enabled?).and_return(false)
        allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(true)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(mock_agent_runner_service)
      end

      context 'when the runner reports a transient failure' do
        before do
          allow(mock_agent_runner_service).to receive(:generate_response).and_return({
                                                                                       'response' => 'conversation_handoff',
                                                                                       'error' => 'server error',
                                                                                       'failure_class' => 'transient',
                                                                                       'handoff_tool_called' => false
                                                                                     })
        end

        it 'does not hand off — it is retried at the job level instead (see retry_on above)' do
          described_class.perform_now(conversation, assistant)

          expect(conversation.reload.status).to eq('pending')
          expect(conversation.messages.outgoing).to be_empty
        end
      end

      context 'when the runner reports a configuration failure' do
        before do
          allow(mock_agent_runner_service).to receive(:generate_response).and_return({
                                                                                       'response' => 'conversation_handoff',
                                                                                       'error' => 'Incorrect API key provided',
                                                                                       'failure_class' => 'configuration',
                                                                                       'handoff_tool_called' => false
                                                                                     })
        end

        it 'hands off and leaves a private diagnostic note' do
          described_class.perform_now(conversation, assistant)
          conversation.reload

          expect(conversation.status).to eq('open')
          expect(conversation.messages.where(private: true).last.content)
            .to include('configuration', 'Incorrect API key provided')
        end
      end
    end
  end

  # Unit-level coverage of the counting/opening/closing logic itself lives in
  # spec/enterprise/lib/captain/credential_circuit_breaker_spec.rb; this only
  # confirms the job actually wires into it at the right points.
  describe 'credential circuit breaker' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }

    before do
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(account).to receive(:feature_enabled?).and_return(false)
      allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
    end

    after { Captain::CredentialCircuitBreaker.close!(account) }

    context 'when the circuit is already open for this account' do
      before do
        Captain::CredentialCircuitBreaker::FAILURE_THRESHOLD.times { Captain::CredentialCircuitBreaker.record_failure!(account) }
      end

      it 'hands off without ever attempting the LLM call' do
        expect(Captain::Llm::AssistantChatService).not_to receive(:new)

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'still leaves a diagnostic note explaining why' do
        described_class.perform_now(conversation, assistant)

        note = conversation.reload.messages.where(private: true).last
        expect(note.content).to include('configuration')
      end
    end

    context 'when repeated configuration failures occur across separate incoming messages' do
      before do
        allow(mock_llm_chat_service).to receive(:generate_response)
          .and_raise(RubyLLM::UnauthorizedError.new('Incorrect API key provided'))
      end

      # One fresh conversation per failure: a failure-triggered handoff now
      # marks the conversation as handed off (Conversation#bot_handoff! →
      # Captain::HumanTakeoverEvaluator#captain_handoff_pending?), so the same
      # conversation would never reach the LLM a second time. The breaker is
      # account-scoped, which is what this protects — every new conversation
      # on a dead credential used to pay for a doomed call.
      it 'opens the circuit once the failure threshold is reached' do
        Captain::CredentialCircuitBreaker::FAILURE_THRESHOLD.times do
          failing_conversation = create(:conversation, inbox: inbox, account: account, status: :pending)
          create(:message, conversation: failing_conversation, content: 'Hello', message_type: :incoming)

          described_class.perform_now(failing_conversation, assistant)
        end

        expect(Captain::CredentialCircuitBreaker.open?(account)).to be(true)
      end

      it 'does not retry the same conversation once its failure handoff has marked it as handed off' do
        described_class.perform_now(conversation, assistant)
        described_class.perform_now(conversation, assistant)

        expect(mock_llm_chat_service).to have_received(:generate_response).once
      end
    end
  end

  # Unit-level coverage of the flag itself lives in spec/lib/llm/config_spec.rb;
  # this only confirms the job actually gates on it at the right point.
  describe 'global credential fallback' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }

    before do
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(account).to receive(:feature_enabled?).and_return(false)
      allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'Hey there' })
    end

    context 'when the operator has not restricted the global fallback (default)' do
      it 'still runs the LLM even though the account has no credential of its own' do
        expect(Captain::Llm::AssistantChatService).to receive(:new)

        described_class.perform_now(conversation, assistant)
      end
    end

    context 'when the global fallback is turned off and the account has no credential of its own' do
      before { InstallationConfig.find_or_create_by!(name: 'CAPTAIN_ALLOW_GLOBAL_FALLBACK') { |c| c.value = 'false' } }

      it 'hands off without ever attempting the LLM call' do
        expect(Captain::Llm::AssistantChatService).not_to receive(:new)

        described_class.perform_now(conversation, assistant)

        expect(conversation.reload.status).to eq('open')
      end

      it 'leaves a diagnostic note explaining the account has no provider configured' do
        described_class.perform_now(conversation, assistant)

        note = conversation.reload.messages.where(private: true).last
        expect(note.content).to include('no tiene un proveedor de IA configurado')
      end
    end

    context 'when the global fallback is turned off but the account has its own credential' do
      before do
        InstallationConfig.find_or_create_by!(name: 'CAPTAIN_ALLOW_GLOBAL_FALLBACK') { |c| c.value = 'false' }
        allow(Platform::Models::Resolver).to receive(:resolve)
          .with(account: account, feature: 'assistant')
          .and_return({ credential: instance_double(Platform::Credential) })
      end

      it 'runs the LLM normally' do
        expect(Captain::Llm::AssistantChatService).to receive(:new)

        described_class.perform_now(conversation, assistant)
      end
    end
  end

  describe 'out of office message after handoff' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }

    before do
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      allow(account).to receive(:feature_enabled?).and_return(false)
      allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
    end

    context 'when handoff occurs outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed. Please leave your email.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'sends out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        ooo_message = conversation.messages.template.last
        expect(ooo_message.content).to eq('We are currently closed. Please leave your email.')
      end
    end

    context 'when handoff occurs within business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          open_all_day: true,
          closed_all_day: false
        )
        allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'does not send out of office message after handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })

        expect(conversation.reload.status).to eq('open')
      end
    end

    context 'when handoff occurs due to error outside business hours' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: 'We are currently closed.'
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(mock_llm_chat_service).to receive(:generate_response).and_raise(StandardError, 'API error')
      end

      it 'sends out of office message after error-triggered handoff' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.to change { conversation.messages.template.count }.by(1)

        expect(conversation.reload.status).to eq('open')
        ooo_message = conversation.messages.template.last
        expect(ooo_message.content).to eq('We are currently closed.')
      end
    end

    context 'when no out of office message is configured' do
      before do
        inbox.update!(
          working_hours_enabled: true,
          out_of_office_message: nil
        )
        inbox.working_hours.find_by(day_of_week: Time.current.in_time_zone(inbox.timezone).wday).update!(
          closed_all_day: true,
          open_all_day: false
        )
        allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'conversation_handoff' })
      end

      it 'does not send out of office message' do
        expect do
          described_class.perform_now(conversation, assistant)
        end.not_to(change { conversation.messages.template.count })
      end
    end
  end

  # Message-shaping rules (history window, truncation, human-vs-bot role
  # attribution) have their own detailed coverage in
  # spec/enterprise/services/captain/conversation/history_builder_spec.rb.
  # This just confirms the job actually wires that builder in.
  describe 'conversation history for the LLM' do
    let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :pending) }
    let(:mock_llm_chat_service) { instance_double(Captain::Llm::AssistantChatService) }
    let(:agent) { create(:user, account: account) }

    before do
      allow(account).to receive(:feature_enabled?).and_return(false)
      allow(account).to receive(:feature_enabled?).with('captain_integration_v2').and_return(false)
      allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_chat_service)
      allow(mock_llm_chat_service).to receive(:generate_response).and_return({ 'response' => 'ok' })
      # A human agent's own outgoing message correctly trips
      # Captain::HumanTakeoverEvaluator in real usage (a human already
      # replied publicly, so the bot should go quiet) — that's working
      # as intended, but it's a different concern from what this describe
      # block tests (HistoryBuilder wiring), and without it every example
      # here that creates such a message would short-circuit in
      # #conversation_captain_controllable? before generate_response is
      # ever reached. Caught by running this spec against a real Postgres
      # for the first time this session (2026-08-28).
      allow_any_instance_of(Captain::HumanTakeoverEvaluator).to receive(:human_takeover?).and_return(false) # rubocop:disable RSpec/AnyInstance
    end

    it "never presents a human agent's own reply to the LLM as the assistant's own words" do
      create(:message, conversation: conversation, content: 'Hola', message_type: :incoming)
      create(:message, conversation: conversation, content: 'Nota de un agente', message_type: :outgoing,
                       sender: agent, account: account)

      expect(mock_llm_chat_service).to receive(:generate_response) do |**kwargs|
        history = kwargs[:message_history]
        expect(history).to eq([
                                { content: 'Hola', role: 'user' },
                                {
                                  content: "#{Captain::Conversation::HistoryBuilder::HUMAN_AGENT_MESSAGE_PREFIX}Nota de un agente",
                                  role: 'user'
                                }
                              ])
        { 'response' => 'ok' }
      end

      described_class.perform_now(conversation, assistant)
    end
  end
end
