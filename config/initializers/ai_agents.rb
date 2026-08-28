# frozen_string_literal: true

# Boot-time warm-up only. Llm::Config.initialize! configures both RubyLLM and
# the ai-agents gem together (fingerprint-gated, cheap to call repeatedly) —
# see lib/llm/config.rb. It's also called before every LLM/agent call site,
# so this just gets errors surfaced in the boot log instead of on first
# request, and avoids a cold DB hit on the very first Captain message.
Rails.application.config.after_initialize do
  Llm::Config.initialize!
rescue StandardError => e
  Rails.logger.error "Failed to configure AI Agents SDK: #{e.message}"
end
