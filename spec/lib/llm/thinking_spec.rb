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
  end
end
