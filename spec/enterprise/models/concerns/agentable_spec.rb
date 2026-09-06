# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Concerns::Agentable do
  let(:dummy_class) do
    Class.new do
      include Concerns::Agentable

      attr_accessor :temperature

      def initialize(name: 'Test Agent', temperature: 0.8)
        @name = name
        @temperature = temperature
      end

      def self.name
        'DummyClass'
      end

      private

      def agent_name
        @name
      end

      def prompt_context
        { base_key: 'base_value' }
      end

      def reasoning_level_value
        Llm::Thinking::OFF
      end
    end
  end

  let(:dummy_instance) { dummy_class.new }
  let(:mock_agents_agent) { instance_double(Agents::Agent) }
  let(:mock_installation_config) { instance_double(InstallationConfig, value: 'gpt-4-turbo') }

  before do
    allow(Agents::Agent).to receive(:new).and_return(mock_agents_agent)
    # `create(:account)` in a couple of examples below triggers
    # Featurable#enable_default_features, which does its own unrelated
    # InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS') call —
    # fall through to the real implementation for any name other than the one
    # this spec actually cares about.
    allow(InstallationConfig).to receive(:find_by).and_call_original
    allow(InstallationConfig).to receive(:find_by).with(name: 'CAPTAIN_OPEN_AI_MODEL').and_return(mock_installation_config)
    allow(Captain::PromptRenderer).to receive(:render).and_return('rendered_template')
  end

  describe '#agent' do
    it 'creates an Agents::Agent with correct parameters' do
      expect(Agents::Agent).to receive(:new).with(
        name: 'Test Agent',
        instructions: instance_of(Proc),
        tools: [],
        model: 'gpt-4-turbo',
        temperature: 0.8,
        response_schema: Captain::ResponseSchema,
        # No thinking params for gpt-4-turbo (not a reasoning model), just the
        # reply-length cap — see Llm::OutputLimit.
        params: { max_tokens: Llm::OutputLimit::DEFAULT_MAX_TOKENS }
      )

      dummy_instance.agent
    end

    it 'caps the reply length alongside the thinking params, without either clobbering the other' do
      allow(InstallationConfig).to receive(:find_by).with(name: 'CAPTAIN_OPEN_AI_MODEL').and_return(
        instance_double(InstallationConfig, value: 'gemini-2.5-flash')
      )
      allow(dummy_instance).to receive_messages(agent_provider: 'gemini',
                                                agent_thinking_params: { generationConfig: { thinkingConfig: { thinkingBudget: 0 } } })

      expect(Agents::Agent).to receive(:new).with(
        hash_including(params: { generationConfig: { thinkingConfig: { thinkingBudget: 0 },
                                                     maxOutputTokens: Llm::OutputLimit::DEFAULT_MAX_TOKENS } })
      )

      dummy_instance.agent
    end

    it 'defaults a nil temperature to 0.7' do
      dummy_instance.temperature = nil

      expect(Agents::Agent).to receive(:new).with(
        hash_including(temperature: 0.7)
      )

      dummy_instance.agent
    end

    it 'converts temperature to float' do
      dummy_instance.temperature = '0.5'

      expect(Agents::Agent).to receive(:new).with(
        hash_including(temperature: 0.5)
      )

      dummy_instance.agent
    end
  end

  describe '#agent_instructions' do
    it 'calls Captain::PromptRenderer with base context' do
      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(base_key: 'base_value')
      )

      dummy_instance.agent_instructions
    end

    it 'merges context state when provided' do
      context_double = instance_double(Agents::RunContext,
                                       context: {
                                         state: {
                                           assistant_config: { 'feature_contact_attributes' => true },
                                           conversation: { id: 123 },
                                           contact: { name: 'John' }
                                         }
                                       })

      expected_context = {
        base_key: 'base_value',
        conversation: { id: 123 },
        contact: { name: 'John' },
        campaign: {}
      }

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(expected_context)
      )

      dummy_instance.agent_instructions(context_double)
    end

    # Pre-fetched FAQs deliberately do NOT reach the system prompt — they ride
    # on the user message so the prompt stays cacheable across turns. See
    # Captain::KnowledgePrefetcher.
    it 'never puts per-message knowledge into the prompt context' do
      context = instance_double(Agents::RunContext, context: { state: { knowledge: "Question: q\nAnswer: a\n" } })

      expect(Captain::PromptRenderer).to receive(:render) do |_template, rendered|
        expect(rendered).not_to have_key('knowledge')
      end

      dummy_instance.agent_instructions(context)
    end

    it 'tells the prompt whether the channel renders plain text (WhatsApp/SMS) or Markdown' do
      whatsapp_context = instance_double(Agents::RunContext, context: { state: { channel_type: 'Channel::Api' } })
      widget_context = instance_double(Agents::RunContext, context: { state: { channel_type: 'Channel::WebWidget' } })

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class', hash_including(channel_type: 'Channel::Api', plain_text_channel: true)
      )
      dummy_instance.agent_instructions(whatsapp_context)

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class', hash_including(channel_type: 'Channel::WebWidget', plain_text_channel: false)
      )
      dummy_instance.agent_instructions(widget_context)
    end

    it 'merges campaign data from context state' do
      context_double = instance_double(Agents::RunContext,
                                       context: {
                                         state: {
                                           conversation: { id: 123 },
                                           contact: { name: 'John' },
                                           campaign: { id: 10, title: 'Summer Sale', message: 'Check it out' }
                                         }
                                       })

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          campaign: { id: 10, title: 'Summer Sale', message: 'Check it out' }
        )
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'handles context without state' do
      context_double = instance_double(Agents::RunContext, context: {})

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          base_key: 'base_value',
          conversation: {},
          contact: nil,
          campaign: {}
        )
      )

      dummy_instance.agent_instructions(context_double)
    end
  end

  describe '#template_name' do
    it 'returns underscored class name' do
      expect(dummy_instance.send(:template_name)).to eq('dummy_class')
    end
  end

  describe '#agent_tools' do
    it 'returns empty array by default' do
      expect(dummy_instance.send(:agent_tools)).to eq([])
    end
  end

  describe '#agent_model' do
    it 'returns value from InstallationConfig when present' do
      expect(dummy_instance.send(:agent_model)).to eq('gpt-4-turbo')
    end

    it 'returns default model when config not found' do
      allow(InstallationConfig).to receive(:find_by).and_return(nil)

      expect(dummy_instance.send(:agent_model)).to eq('gpt-4.1')
    end

    it 'returns default model when config value is nil' do
      allow(mock_installation_config).to receive(:value).and_return(nil)

      expect(dummy_instance.send(:agent_model)).to eq('gpt-4.1')
    end

    it "resolves the account's configured provider model when present" do
      account = create(:account)
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash-preview', kind: 'chat', enabled: true)

      account_aware = Class.new(dummy_class) do
        define_method(:account) { @account }
      end.new
      account_aware.instance_variable_set(:@account, account)

      expect(account_aware.send(:agent_model)).to eq('gemini-3-flash-preview')
    end
  end

  describe '#agent_response_schema' do
    it 'returns Captain::ResponseSchema for non-gemini providers' do
      expect(dummy_instance.send(:agent_response_schema)).to eq(Captain::ResponseSchema)
    end

    it 'returns nil for gemini (avoids function-calling + JSON mime type conflict)' do
      account = create(:account)
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash', kind: 'chat', enabled: true)

      account_aware = Class.new(dummy_class) do
        define_method(:account) { @account }
      end.new
      account_aware.instance_variable_set(:@account, account)

      expect(account_aware.send(:agent_provider)).to eq('gemini')
      expect(account_aware.send(:agent_response_schema)).to be_nil
    end
  end

  describe 'required methods' do
    let(:incomplete_class) do
      Class.new do
        include Concerns::Agentable
      end
    end

    let(:incomplete_instance) { incomplete_class.new }

    describe '#agent_name' do
      it 'raises NotImplementedError when not implemented' do
        expect { incomplete_instance.send(:agent_name) }
          .to raise_error(NotImplementedError, /must implement agent_name/)
      end
    end

    describe '#prompt_context' do
      it 'raises NotImplementedError when not implemented' do
        expect { incomplete_instance.send(:prompt_context) }
          .to raise_error(NotImplementedError, /must implement prompt_context/)
      end
    end
  end
end
