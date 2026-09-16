require 'rails_helper'

RSpec.describe 'RubyLLM thread context patch' do
  after { Thread.current[RubyLLM::THREAD_CONTEXT_KEY] = nil }

  describe '.with_thread_context' do
    it 'exposes the context within the block and restores it afterwards' do
      context = instance_double(RubyLLM::Context)

      expect(RubyLLM.thread_context).to be_nil
      RubyLLM.with_thread_context(context) do
        expect(RubyLLM.thread_context).to eq(context)
      end
      expect(RubyLLM.thread_context).to be_nil
    end

    it 'is a no-op (still yields) for a nil context' do
      expect { |b| RubyLLM.with_thread_context(nil, &b) }.to yield_control
      expect(RubyLLM.thread_context).to be_nil
    end

    it 'restores the previous context even when the block raises' do
      context = instance_double(RubyLLM::Context)

      expect do
        RubyLLM.with_thread_context(context) { raise 'boom' }
      end.to raise_error('boom')
      expect(RubyLLM.thread_context).to be_nil
    end
  end

  # Provider routing (as opposed to the credential context above) moved to
  # Concerns::Agentable#agent passing provider:/assume_model_exists: on each
  # Agents::Agent directly (ai-agents >= 0.11/0.12, see docs/adaki/
  # captain-plan-latencia-2026-09.md fase 6) — see spec/enterprise/models/
  # concerns/agentable_spec.rb for that behavior. This patch now only injects
  # the context (API key), which RubyLLM::Chat.new still needs regardless of
  # who supplies provider/assume_model_exists.
  describe 'RubyLLM::Chat.new with an explicit provider/assume_model_exists (as ai-agents now supplies)' do
    before do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'global-key')
      Llm::Config.reset!
    end

    let(:context) { Llm::Config.context_for('gemini-key', provider: 'gemini') }

    it 'inherits the thread context for its api key while honoring the caller-supplied provider/assume_model_exists' do
      chat = RubyLLM.with_thread_context(context) do
        RubyLLM::Chat.new(model: 'gemini-9.9-flash-lite', provider: 'gemini', assume_model_exists: true)
      end

      expect(chat.model.id).to eq('gemini-9.9-flash-lite')
      expect(chat.model.provider).to eq('gemini')
      expect(chat.instance_variable_get(:@config).gemini_api_key).to eq('gemini-key')
    end

    it 'still raises for an unknown model when the caller does not assume it exists' do
      expect do
        RubyLLM.with_thread_context(context) { RubyLLM::Chat.new(model: 'gemini-9.9-flash-lite', provider: 'gemini') }
      end.to raise_error(RubyLLM::ModelNotFoundError)
    end
  end

  describe 'RubyLLM::Chat.new' do
    before do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'global-key')
      Llm::Config.reset!
    end

    it 'inherits the thread context when none is explicitly passed' do
      context = Llm::Config.context_for('sk-threadkey', provider: 'openai')

      chat = RubyLLM.with_thread_context(context) { RubyLLM::Chat.new(model: 'gpt-4.1-mini') }

      expect(chat.instance_variable_get(:@config).openai_api_key).to eq('sk-threadkey')
    end

    it 'prefers an explicit context over the thread context' do
      thread_context = Llm::Config.context_for('sk-threadkey', provider: 'openai')
      explicit_context = Llm::Config.context_for('sk-explicit', provider: 'openai')

      chat = RubyLLM.with_thread_context(thread_context) do
        RubyLLM::Chat.new(model: 'gpt-4.1-mini', context: explicit_context)
      end

      expect(chat.instance_variable_get(:@config).openai_api_key).to eq('sk-explicit')
    end
  end
end
