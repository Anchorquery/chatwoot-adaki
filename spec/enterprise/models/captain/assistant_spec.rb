require 'rails_helper'

RSpec.describe Captain::Assistant do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '#reasoning_level_value' do
    it 'defaults to off, so a support bot does not pay for unbounded reasoning' do
      expect(assistant.reasoning_level_value).to eq(Llm::Thinking::OFF)
    end

    it 'honors a configured level' do
      assistant.update!(config: assistant.config.merge('reasoning_level' => 'low'))

      expect(assistant.reasoning_level_value).to eq('low')
    end

    it 'falls back to off for a value that is not a known level' do
      assistant.update!(config: assistant.config.merge('reasoning_level' => 'turbo'))

      expect(assistant.reasoning_level_value).to eq(Llm::Thinking::OFF)
    end
  end

  describe '#agent' do
    before do
      allow(assistant).to receive_messages(agent_provider: 'gemini', agent_model: 'gemini-2.5-flash')
    end

    it 'passes the thinking params to the agent so they reach the provider payload' do
      expect(assistant.agent.params).to eq({ generationConfig: { thinkingConfig: { thinkingBudget: 0 } } })
    end

    it 'passes no params when the level is dynamic' do
      assistant.update!(config: assistant.config.merge('reasoning_level' => 'dynamic'))

      expect(assistant.agent.params).to eq({})
    end

    it 'gives a scenario agent the same level as its assistant' do
      assistant.update!(config: assistant.config.merge('reasoning_level' => 'low'))
      scenario = create(:captain_scenario, assistant: assistant, account: account)
      allow(scenario).to receive_messages(agent_provider: 'gemini', agent_model: 'gemini-2.5-flash')

      expect(scenario.agent.params.dig(:generationConfig, :thinkingConfig, :thinkingBudget))
        .to eq(Llm::Thinking::FLASH_LOW_BUDGET)
    end
  end
end
