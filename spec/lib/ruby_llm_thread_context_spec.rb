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

  describe '.with_thread_context with a provider' do
    it 'exposes the provider within the block and restores it afterwards' do
      context = instance_double(RubyLLM::Context)

      RubyLLM.with_thread_context(context, provider: 'gemini') do
        expect(RubyLLM.thread_provider).to eq('gemini')
      end
      expect(RubyLLM.thread_provider).to be_nil
    end
  end

  describe 'RubyLLM::Chat.new with a model the static registry does not know' do
    before do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'global-key')
      Llm::Config.reset!
    end

    let(:context) { Llm::Config.context_for('gemini-key', provider: 'gemini') }

    # Regression: Captain's slugs come from the provider's live model list, so a
    # freshly released model (gemini-3.1-flash-lite, 2026-09-04) is valid at
    # Google and still ModelNotFoundError for RubyLLM's static registry.
    it 'assumes the model exists for the thread provider instead of raising' do
      chat = RubyLLM.with_thread_context(context, provider: 'gemini') do
        RubyLLM::Chat.new(model: 'gemini-9.9-flash-lite')
      end

      expect(chat.model.id).to eq('gemini-9.9-flash-lite')
      expect(chat.model.provider).to eq('gemini')
      expect(chat.model.supports_functions?).to be(true)
    end

    it 'also covers a later model switch on the same chat (scenario handoffs)' do
      chat = RubyLLM.with_thread_context(context, provider: 'gemini') do
        RubyLLM::Chat.new(model: 'gemini-2.5-flash').with_model('gemini-9.9-pro')
      end

      expect(chat.model.id).to eq('gemini-9.9-pro')
      expect(chat.model.provider).to eq('gemini')
    end

    it 'still raises when no thread provider is published' do
      expect do
        RubyLLM.with_thread_context(context) { RubyLLM::Chat.new(model: 'gemini-9.9-flash-lite') }
      end.to raise_error(RubyLLM::ModelNotFoundError)
    end

    it 'does not touch a model the registry already knows' do
      chat = RubyLLM.with_thread_context(context, provider: 'gemini') do
        RubyLLM::Chat.new(model: 'gemini-2.5-flash')
      end

      expect(chat.model.id).to eq('gemini-2.5-flash')
      expect(chat.model.metadata[:warning]).to be_nil
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
