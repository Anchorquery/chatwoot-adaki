# frozen_string_literal: true

# RubyLLM generates an internal UUID for Gemini function calls but drops it
# when serializing the request/response pair. Gemini's current API requires
# the same call id in the function response; without it, tool turns can end in
# finishReason=STOP with no text. Keep this compatibility shim local so a gem
# upgrade can remove it once RubyLLM includes the fix.
#
# Re-verified against ruby_llm 1.16.0 (docs/adaki/captain-plan-latencia-2026-09.md
# fase 6): RubyLLM::Providers::Gemini::Tools#format_tool_call/#format_tool_result
# still build functionCall/functionResponse without an `id` key — still needed.
# See spec/lib/ruby_llm_gemini_tool_call_ids_spec.rb.
module AdakiGeminiToolCallIds
  def format_tool_call(message)
    parts = super
    calls = message.tool_calls.values
    call_index = 0

    parts.each do |part|
      function_call = part[:functionCall]
      next unless function_call

      call = calls[call_index]
      call_index += 1
      next unless call

      function_call[:id] = call.id
    end

    parts
  end

  def format_tool_result(message, function_name = nil)
    parts = super
    tool_call_id = message.tool_call_id
    return parts if tool_call_id.to_s.empty?

    parts.each do |part|
      function_response = part[:functionResponse]
      function_response[:id] = tool_call_id if function_response
    end

    parts
  end
end

Rails.application.config.to_prepare do
  tools = RubyLLM::Providers::Gemini::Tools
  tools.prepend(AdakiGeminiToolCallIds) unless tools.ancestors.include?(AdakiGeminiToolCallIds)
end
