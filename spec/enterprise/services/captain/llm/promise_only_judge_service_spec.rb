require 'rails_helper'

RSpec.describe Captain::Llm::PromiseOnlyJudgeService do
  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account, reply_text: 'Let me check that for you') }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_context) { instance_double(RubyLLM::Context, chat: mock_chat) }
  let(:mock_response) { instance_double(RubyLLM::Message, content: 'OK', input_tokens: 10, output_tokens: 1) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
    allow(Llm::Config).to receive(:with_api_key).and_yield(mock_context)
    allow(mock_chat).to receive(:with_instructions)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
  end

  describe '#perform' do
    it 'returns true when the model says RETRY' do
      allow(mock_response).to receive(:content).and_return('RETRY')

      expect(service.perform).to be(true)
    end

    it 'returns false when the model says OK' do
      allow(mock_response).to receive(:content).and_return('OK')

      expect(service.perform).to be(false)
    end

    it 'is case/whitespace tolerant' do
      allow(mock_response).to receive(:content).and_return("  retry\n")

      expect(service.perform).to be(true)
    end

    it 'sends the draft reply as the only user message, with the judge instructions as system prompt' do
      expect(mock_chat).to receive(:with_instructions).with(a_string_including('RETRY'))
      expect(mock_chat).to receive(:ask).with('Let me check that for you').and_return(mock_response)

      service.perform
    end

    it 'does not count toward the account response quota' do
      allow(account).to receive(:increment_response_usage)

      service.perform

      expect(account).not_to have_received(:increment_response_usage)
    end

    # Enterprise::Captain::BaseTaskService (prepended into every
    # Captain::BaseTaskService) short-circuits #perform into a raw
    # { error: } hash before this class's own body runs at all — callers
    # (AgentRunnerService#promise_only_confirmed?) treat anything other than
    # a literal `false` as fail-open, which this Hash satisfies too.
    it 'returns the enterprise wrapper error hash as-is when captain_tasks is disabled, never a false' do
      allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(false)

      expect(service.perform).to be_a(Hash).and(satisfy { |r| r[:error].present? })
    end

    it 'fails open (true) when the provider call errors' do
      allow(mock_chat).to receive(:ask).and_raise(RubyLLM::Error, 'boom')

      expect(service.perform).to be(true)
    end
  end
end
