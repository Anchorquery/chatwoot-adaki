require 'rails_helper'

RSpec.describe Llm::Config do
  describe '.with_api_key' do
    it 'routes a gemini credential to the gemini setter' do
      described_class.with_api_key('AIza-key', provider: 'gemini') do |context|
        expect(context.config.gemini_api_key).to eq('AIza-key')
      end
    end

    it 'routes an openai credential to the openai setter' do
      described_class.with_api_key('sk-key', provider: 'openai') do |context|
        expect(context.config.openai_api_key).to eq('sk-key')
      end
    end

    it 'falls back to the openai-compatible client for unknown providers and warns' do
      allow(Rails.logger).to receive(:warn)

      described_class.with_api_key('key', provider: 'mistral') do |context|
        expect(context.config.openai_api_key).to eq('key')
      end

      expect(Rails.logger).to have_received(:warn).with(/not fully supported/)
    end
  end

  describe '.context_for_credential' do
    let(:account) { create(:account) }

    it 'returns nil for a blank credential' do
      expect(described_class.context_for_credential(nil)).to be_nil
    end

    it 'builds a context routed by the credential provider, honoring api_base' do
      credential = create(:platform_credential, :gemini, account: account, metadata: { 'api_base' => 'https://example.test' })

      context = described_class.context_for_credential(credential)

      expect(context).to be_present
      expect(context.config.gemini_api_key).to eq('AIzaSy-test-gemini-key')
      expect(context.config.gemini_api_base).to eq('https://example.test')
    end

    it 'returns nil when the credential carries no api key' do
      credential = create(:platform_credential, account: account, payload: {})

      expect(described_class.context_for_credential(credential)).to be_nil
    end
  end
end
