# frozen_string_literal: true

# RubyLLM 1.15 generates an internal UUID for Gemini function calls but drops
# it when serializing the request/response pair. Gemini's current API requires
# the same call id in the function response; without it, tool turns can end in
# finishReason=STOP with no text. Keep this compatibility shim local so a gem
# upgrade can remove it once RubyLLM includes the fix.
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
