require 'rails_helper'

RSpec.describe Llm::Config do
  # Llm::Config only memoizes a fingerprint of provider_values, never the
  # values themselves — provider_values re-reads InstallationConfig fresh on
  # every call (see lib/llm/config.rb). That means these specs are safe from
  # cross-example pollution as long as they always end by restoring
  # @configured_fingerprint to what it was before the example ran, so a
  # later spec file's first #initialize! call still sees a "changed"
  # fingerprint and actually reconfigures instead of silently no-op'ing.
  around do |example|
    original_fingerprint = described_class.instance_variable_get(:@configured_fingerprint)
    example.run
    described_class.instance_variable_set(:@configured_fingerprint, original_fingerprint)
  end

  describe '.global_fallback_allowed?' do
    it 'defaults to true when no InstallationConfig row exists (unchanged behavior)' do
      expect(described_class.global_fallback_allowed?).to be(true)
    end

    it 'is false once the operator explicitly turns it off' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_ALLOW_GLOBAL_FALLBACK') { |c| c.value = 'false' }

      expect(described_class.global_fallback_allowed?).to be(false)
    end

    it 'is true when explicitly set to true' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_ALLOW_GLOBAL_FALLBACK') { |c| c.value = 'true' }

      expect(described_class.global_fallback_allowed?).to be(true)
    end
  end

  describe '.initialize!' do
    before { described_class.reset! }

    it 'strips whitespace from a key before configuring RubyLLM' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = "  sk-padded-key \n" }

      described_class.initialize!

      expect(RubyLLM.config.openai_api_key).to eq('sk-padded-key')
    end

    it 'configures the ai-agents gem alongside RubyLLM when an OpenAI key is present' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = 'sk-agents-key' }
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_MODEL') { |c| c.value = 'gpt-4.1-nano' }

      described_class.initialize!

      expect(Agents.configuration.openai_api_key).to eq('sk-agents-key')
      expect(Agents.configuration.default_model).to eq('gpt-4.1-nano')
    end

    it 'does not re-run RubyLLM.configure when nothing changed since the last call' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = 'sk-key' }
      described_class.initialize!

      allow(RubyLLM).to receive(:configure)
      described_class.initialize!

      expect(RubyLLM).not_to have_received(:configure)
    end

    it 'reconfigures once a provider value actually changes, without a restart' do
      config = InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = 'sk-old' }
      described_class.initialize!

      config.update!(value: 'sk-new')
      described_class.initialize!

      expect(RubyLLM.config.openai_api_key).to eq('sk-new')
    end

    it 'reconfigures after #reset! even when values are unchanged' do
      InstallationConfig.find_or_create_by!(name: 'CAPTAIN_OPEN_AI_API_KEY') { |c| c.value = 'sk-key' }
      described_class.initialize!
      described_class.reset!

      allow(RubyLLM).to receive(:configure).and_call_original
      described_class.initialize!

      # at_least(:once), not a fixed count: configure_agents_sdk delegates to
      # Agents.configure, which internally calls RubyLLM.configure a second
      # time on top of our own direct call — an ai-agents gem implementation
      # detail this test shouldn't be coupled to. What matters is that a
      # reconfigure actually happened.
      expect(RubyLLM).to have_received(:configure).at_least(:once)
    end
  end

  describe '.initialized?' do
    before { described_class.reset! }

    it 'is false before the first call' do
      expect(described_class.initialized?).to be(false)
    end

    it 'is true once initialize! has run' do
      described_class.initialize!

      expect(described_class.initialized?).to be(true)
    end
  end

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
      # payload: {} is rejected outright by the model's `presence: true`
      # validation on encrypted_payload (an empty Hash is blank). A payload
      # with unrelated content but no api_key key is what actually exercises
      # this nil-fallback path.
      credential = create(:platform_credential, account: account, payload: { 'other' => 'x' })

      expect(described_class.context_for_credential(credential)).to be_nil
    end
  end
end
