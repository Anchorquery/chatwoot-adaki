require 'rails_helper'

RSpec.describe Llm::BaseAiService do
  subject(:service) { described_class.new }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
  end

  describe '#sanitize_json_response' do
    it 'strips ```json fences' do
      input = "```json\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'strips bare ``` fences' do
      input = "```\n{\"key\": \"value\"}\n```"
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'passes through plain JSON unchanged' do
      input = '{"key": "value"}'
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end

    it 'returns nil for nil input' do
      expect(service.send(:sanitize_json_response, nil)).to be_nil
    end

    it 'strips surrounding whitespace' do
      input = "  \n{\"key\": \"value\"}\n  "
      expect(service.send(:sanitize_json_response, input)).to eq('{"key": "value"}')
    end
  end

  describe '#json_mode_params' do
    it 'uses response_format for openai' do
      allow(service).to receive(:llm_request_provider).and_return('openai')
      expect(service.send(:json_mode_params)).to eq(response_format: { type: 'json_object' })
    end

    it 'uses generationConfig for gemini' do
      allow(service).to receive(:llm_request_provider).and_return('gemini')
      expect(service.send(:json_mode_params)).to eq(generationConfig: { responseMimeType: 'application/json' })
    end

    it 'omits the provider-specific hint for unknown providers but keeps extra params' do
      allow(service).to receive(:llm_request_provider).and_return('mistral')
      expect(service.send(:json_mode_params, max_tokens: 100)).to eq(max_tokens: 100)
    end
  end

  describe '#setup_model' do
    let(:account) { create(:account) }

    it 'builds a per-credential llm context routed to the resolved provider' do
      credential = create(:platform_credential, :gemini, account: account)
      create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash', kind: 'chat', enabled: true)

      klass = Class.new(described_class) do
        define_method(:resolver_account) { @resolver_account }
        define_method(:feature_key) { 'assistant' }
      end

      instance = klass.allocate
      instance.instance_variable_set(:@resolver_account, account)
      instance.send(:setup_model)

      expect(instance.instance_variable_get(:@model)).to eq('gemini-3-flash')
      context = instance.instance_variable_get(:@llm_context)
      expect(context).to be_present
      expect(context.config.gemini_api_key).to eq('AIzaSy-test-gemini-key')
    end
  end
end
