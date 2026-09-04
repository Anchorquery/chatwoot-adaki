require 'rails_helper'

RSpec.describe Llm::Thinking do
  describe '.normalize_level' do
    it 'accepts the known levels' do
      expect(described_class.normalize_level('low')).to eq('low')
      expect(described_class.normalize_level(:dynamic)).to eq('dynamic')
    end

    it 'falls back to off for anything unknown or blank' do
      expect(described_class.normalize_level(nil)).to eq('off')
      expect(described_class.normalize_level('')).to eq('off')
      expect(described_class.normalize_level('turbo')).to eq('off')
    end
  end

  describe '.params_for' do
    it 'disables thinking on Gemini Flash' do
      params = described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'off')

      expect(params).to eq({ generationConfig: { thinkingConfig: { thinkingBudget: 0 } } })
    end

    it 'uses the lowest non-zero budget on Gemini Flash when the level is low' do
      params = described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'low')

      expect(params.dig(:generationConfig, :thinkingConfig, :thinkingBudget)).to eq(described_class::FLASH_LOW_BUDGET)
    end

    # Gemini 2.5 Pro rejects a budget of 0 outright, so "off" has to become
    # the API's own floor instead of an invalid request.
    it 'clamps to the minimum budget on Gemini Pro, which cannot disable thinking' do
      %w[off low].each do |level|
        params = described_class.params_for(provider: 'gemini', model: 'gemini-2.5-pro', level: level)

        expect(params.dig(:generationConfig, :thinkingConfig, :thinkingBudget)).to eq(described_class::PRO_MINIMUM_BUDGET)
      end
    end

    it 'uses thinkingLevel instead of a budget on Gemini 3' do
      params = described_class.params_for(provider: 'gemini', model: 'gemini-3-flash', level: 'off')

      expect(params).to eq({ generationConfig: { thinkingConfig: { thinkingLevel: 'minimal' } } })
    end

    it 'uses low as the minimum for Gemini 3 Pro' do
      params = described_class.params_for(provider: 'google', model: 'gemini-3-pro', level: 'off')

      expect(params).to eq({ generationConfig: { thinkingConfig: { thinkingLevel: 'low' } } })
    end

    it 'sends nothing when the level is dynamic, so the provider keeps its own default' do
      expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'dynamic')).to eq({})
    end

    it 'sends nothing for providers with no supported knob here' do
      expect(described_class.params_for(provider: 'openai', model: 'gpt-4.1', level: 'off')).to eq({})
    end

    # OpenAI dropped 'minimal' after the 5.0 family; guessing it for gpt-5.4-mini
    # was a 400 in production (account 4, 2026-09-04).
    it "uses 'minimal' only for the gpt-5.0 family and 'none' for every later release" do
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5-mini', level: 'off')).to eq({ reasoning_effort: 'minimal' })
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5', level: 'off')).to eq({ reasoning_effort: 'minimal' })
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5.1', level: 'off')).to eq({ reasoning_effort: 'none' })
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5.4-mini', level: 'off')).to eq({ reasoning_effort: 'none' })
      expect(described_class.params_for(provider: 'openai', model: 'o3-mini', level: 'off')).to eq({ reasoning_effort: 'low' })
    end

    it "lets the model's own row override the family seed" do
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5.4-mini', level: 'off', supported_efforts: %w[low medium high]))
        .to eq({ reasoning_effort: 'low' })
      expect(described_class.params_for(provider: 'openai', model: 'gpt-5.4-mini', level: 'off', supported_efforts: [])).to eq({})
      expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'off', supported_efforts: %w[low medium]))
        .to eq({ generationConfig: { thinkingConfig: { thinkingBudget: described_class::FLASH_LOW_BUDGET } } })
    end

    it 'sends nothing at all while .without_params is active' do
      described_class.without_params do
        expect(described_class.params_for(provider: 'openai', model: 'gpt-5.4-mini', level: 'off')).to eq({})
        expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'off')).to eq({})
      end

      expect(described_class.params_for(provider: 'gemini', model: 'gemini-2.5-flash', level: 'off')).not_to eq({})
    end

    it 'disables thinking on DeepSeek V4 Flash when reasoning is off' do
      expect(described_class.params_for(provider: 'deepseek', model: 'deepseek-v4-flash', level: 'off')).to eq(
        { thinking: { type: 'disabled' } }
      )
    end

    it 'maps low reasoning to the DeepSeek V4 thinking payload' do
      expect(described_class.params_for(provider: 'deepseek', model: 'deepseek-v4-pro', level: 'low')).to eq(
        { thinking: { type: 'enabled' }, reasoning_effort: 'low' }
      )
    end
  end
end
