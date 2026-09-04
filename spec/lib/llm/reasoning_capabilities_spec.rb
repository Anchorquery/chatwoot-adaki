require 'rails_helper'

RSpec.describe Llm::ReasoningCapabilities do
  describe '.seed_for' do
    {
      %w[openai gpt-5-mini] => %w[minimal low medium high],
      %w[openai gpt-5] => %w[minimal low medium high],
      %w[openai gpt-5.1] => %w[none low medium high],
      %w[openai gpt-5.4-mini] => %w[none low medium high xhigh],
      %w[openai gpt-5.2-codex] => %w[low medium high xhigh],
      %w[openai gpt-5.5-pro] => %w[medium high xhigh],
      %w[openai o3-mini] => %w[low medium high],
      %w[openai gpt-4.1] => [],
      %w[gemini gemini-2.5-flash] => %w[none low medium high],
      %w[gemini gemini-2.5-pro] => %w[low medium high],
      %w[google gemini-3.1-flash-lite] => %w[minimal low medium high],
      %w[gemini gemini-3-pro-preview] => %w[low medium high],
      %w[gemini gemini-2.0-flash] => [],
      %w[deepseek deepseek-v4-flash] => %w[none low medium high],
      %w[deepseek deepseek-chat] => %w[none low medium high],
      %w[anthropic claude-sonnet-4.5] => []
    }.each do |(provider, model), expected|
      it "seeds #{provider}/#{model} with #{expected.inspect}" do
        expect(described_class.seed_for(provider: provider, model: model)).to eq(expected)
      end
    end
  end

  describe '.effort_for_level' do
    it 'maps off to the lowest effort the model offers' do
      expect(described_class.effort_for_level(%w[none low medium high], 'off')).to eq('none')
      expect(described_class.effort_for_level(%w[minimal low medium high], 'off')).to eq('minimal')
      expect(described_class.effort_for_level(%w[low medium high], 'off')).to eq('low')
      expect(described_class.effort_for_level(%w[medium high xhigh], 'off')).to be_nil
      expect(described_class.effort_for_level([], 'off')).to be_nil
    end

    it 'maps low to low or the closest thing available' do
      expect(described_class.effort_for_level(%w[none low medium], 'low')).to eq('low')
      expect(described_class.effort_for_level(%w[minimal medium], 'low')).to eq('minimal')
      expect(described_class.effort_for_level(%w[medium high], 'low')).to eq('medium')
    end

    it 'sends nothing for dynamic' do
      expect(described_class.effort_for_level(%w[none low], 'dynamic')).to be_nil
    end
  end

  describe '.stored_efforts' do
    it 'returns nil when the row says nothing and keeps an explicit empty list' do
      expect(described_class.stored_efforts(nil)).to be_nil
      expect(described_class.stored_efforts({})).to be_nil
      expect(described_class.stored_efforts({ 'supported_efforts' => [] })).to eq([])
      expect(described_class.stored_efforts({ 'supported_efforts' => %w[low bogus] })).to eq(%w[low])
    end
  end

  describe '.parse_supported_values' do
    it "reads OpenAI's list out of the rejection message" do
      message = "Unsupported value: 'reasoning_effort' does not support 'minimal' with this model. " \
                "Supported values are: 'none', 'low', 'medium', 'high', and 'xhigh'."

      expect(described_class.parse_supported_values(message)).to eq(%w[none low medium high xhigh])
    end

    it 'returns nil when the provider names no values' do
      expect(described_class.parse_supported_values('Thinking config is not supported for this model.')).to be_nil
    end
  end

  describe '.learn_from_rejection!' do
    let(:account) { create(:account) }
    let(:credential) { create(:platform_credential, :openai, account: account) }
    let(:row) { create(:platform_credential_model, credential: credential, slug: 'gpt-5.4-mini', reasoning_config: {}) }

    it 'stores the efforts the provider listed, marked as learned' do
      learned = described_class.learn_from_rejection!(row, "Supported values are: 'none', 'low', 'medium', 'high', and 'xhigh'.")

      expect(learned).to eq(%w[none low medium high xhigh])
      expect(row.reload.reasoning_config).to include('supported_efforts' => %w[none low medium high xhigh], 'source' => 'provider')
      expect(row.reasoning_config['learned_at']).to be_present
    end

    it 'records that the model takes no reasoning params when the message lists none' do
      described_class.learn_from_rejection!(row, 'Thinking config is not supported for this model.')

      expect(row.reload.reasoning_config['supported_efforts']).to eq([])
    end

    it 'is a no-op without a row' do
      expect(described_class.learn_from_rejection!(nil, 'whatever')).to be_nil
    end
  end
end
