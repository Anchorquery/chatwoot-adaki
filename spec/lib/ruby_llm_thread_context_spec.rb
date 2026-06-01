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
