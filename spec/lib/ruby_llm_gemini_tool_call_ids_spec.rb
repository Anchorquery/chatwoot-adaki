require 'rails_helper'

# See config/initializers/ruby_llm_gemini_tool_call_ids.rb. Verified against
# ruby_llm 1.16.0's actual RubyLLM::Providers::Gemini::Tools source
# (docs/adaki/captain-plan-latencia-2026-09.md fase 6): format_tool_call/
# format_tool_result still build functionCall/functionResponse without an
# `id` field natively, so this shim is still load-bearing, not something the
# 1.16 upgrade made redundant.
RSpec.describe 'Gemini tool call ids patch' do
  let(:formatter) { Class.new { include RubyLLM::Providers::Gemini::Tools }.new }

  describe '#format_tool_call' do
    it "injects the tool call's own id into functionCall, which RubyLLM does not set natively" do
      tool_call = RubyLLM::ToolCall.new(id: 'call_123', name: 'faq_lookup', arguments: { query: 'precio' })
      message = RubyLLM::Message.new(role: :assistant, content: '', tool_calls: { 'call_123' => tool_call })

      parts = formatter.format_tool_call(message)

      expect(parts.first[:functionCall][:id]).to eq('call_123')
      expect(parts.first[:functionCall][:name]).to eq('faq_lookup')
    end

    it 'matches each part to its own call id when the assistant makes multiple tool calls in one turn' do
      first_call = RubyLLM::ToolCall.new(id: 'call_1', name: 'faq_lookup', arguments: {})
      second_call = RubyLLM::ToolCall.new(id: 'call_2', name: 'add_label_to_conversation', arguments: {})
      message = RubyLLM::Message.new(role: :assistant, content: '', tool_calls: { 'call_1' => first_call, 'call_2' => second_call })

      parts = formatter.format_tool_call(message)

      expect(parts.map { |part| part[:functionCall][:id] }).to eq(%w[call_1 call_2])
    end
  end

  describe '#format_tool_result' do
    it "injects the message's tool_call_id into functionResponse, which RubyLLM does not set natively" do
      message = RubyLLM::Message.new(role: :tool, content: '37,90€', tool_call_id: 'call_123')

      parts = formatter.format_tool_result(message)

      expect(parts.first[:functionResponse][:id]).to eq('call_123')
    end

    it 'leaves functionResponse without an id when the message carries none, instead of injecting a blank one' do
      message = RubyLLM::Message.new(role: :tool, content: '37,90€', tool_call_id: nil)

      parts = formatter.format_tool_result(message)

      expect(parts.first[:functionResponse]).not_to have_key(:id)
    end
  end
end
