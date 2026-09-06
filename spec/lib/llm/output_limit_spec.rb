require 'rails_helper'

RSpec.describe Llm::OutputLimit do
  describe '.params_for' do
    it 'caps Gemini through generationConfig so it deep-merges with the thinking config' do
      params = described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', max_tokens: 800)

      expect(params).to eq({ generationConfig: { maxOutputTokens: 800 } })
    end

    it 'adds the thinking budget on top for Gemini, which counts thinking against the same allowance' do
      thinking = { generationConfig: { thinkingConfig: { thinkingBudget: 512 } } }
      params = described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', max_tokens: 800,
                                          thinking_params: thinking)

      expect(params).to eq({ generationConfig: { maxOutputTokens: 1312 } })
    end

    it 'treats google as gemini' do
      expect(described_class.params_for(provider: 'google', model: 'gemini-2.5-flash', max_tokens: 100))
        .to eq({ generationConfig: { maxOutputTokens: 100 } })
    end

    it 'uses max_completion_tokens for OpenAI reasoning models and max_tokens for the rest' do
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5-mini', max_tokens: 800))
        .to eq({ max_completion_tokens: 800 })
      expect(described_class.params_for(provider: 'openai', model: 'o3', max_tokens: 800))
        .to eq({ max_completion_tokens: 800 })
      expect(described_class.params_for(provider: 'openai', model: 'gpt-4.1-mini', max_tokens: 800))
        .to eq({ max_tokens: 800 })
    end

    it 'uses max_tokens for deepseek and anthropic' do
      expect(described_class.params_for(provider: 'deepseek', model: 'deepseek-v4-flash', max_tokens: 800))
        .to eq({ max_tokens: 800 })
      expect(described_class.params_for(provider: 'anthropic', model: 'claude-x', max_tokens: 800))
        .to eq({ max_tokens: 800 })
    end

    it 'returns nothing for an unknown provider or a non-positive cap' do
      expect(described_class.params_for(provider: 'mistral', model: 'x', max_tokens: 800)).to eq({})
      expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', max_tokens: 0)).to eq({})
      expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', max_tokens: nil)).to eq({})
    end
  end
end
