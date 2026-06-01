# frozen_string_literal: true

# Per-thread default RubyLLM context.
#
# Some integrations (notably the ai-agents gem used by Captain V2) build their
# own `RubyLLM::Chat.new(model:)` from the GLOBAL RubyLLM config and validate
# the provider credential eagerly in Chat.new (Provider#initialize ->
# ensure_configured!). That makes it impossible to route those chats to a
# per-account provider (e.g. an account's Gemini key) after the fact: the chat
# raises `ConfigurationError: Missing configuration for <provider>` before any
# callback can swap the context.
#
# This prepend lets callers publish a context for the current thread via
# `RubyLLM.with_thread_context`. When set, any Chat created on that thread
# without an explicit context inherits it, so the provider is configured from
# the start. It is thread-local (safe under Puma/Sidekiq concurrency) and a
# no-op unless a thread context is active.
require 'ruby_llm'

module RubyLLM
  THREAD_CONTEXT_KEY = :ruby_llm_thread_context

  class << self
    def thread_context
      Thread.current[THREAD_CONTEXT_KEY]
    end

    # Sets the per-thread default context for the duration of the block,
    # restoring the previous value afterwards. Nil context is a no-op.
    def with_thread_context(context)
      return yield if context.nil?

      previous = Thread.current[THREAD_CONTEXT_KEY]
      Thread.current[THREAD_CONTEXT_KEY] = context
      begin
        yield
      ensure
        Thread.current[THREAD_CONTEXT_KEY] = previous
      end
    end
  end

  module ChatThreadContext
    def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
      context ||= RubyLLM.thread_context
      super
    end
  end

  class Chat
    prepend ChatThreadContext
  end
end
