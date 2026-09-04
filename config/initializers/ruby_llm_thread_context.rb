# frozen_string_literal: true

# Per-thread default RubyLLM context (+ provider hint).
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
#
# The same call can publish the provider the context belongs to. The ai-agents
# gem also creates its chats with `model:` only, and RubyLLM then looks the
# slug up in its static registry (config/llm_models.json) — a registry that
# lags behind what the providers actually serve. Captain's model slugs come
# from the provider's live model list (Platform::Models::Importer), so a
# freshly released model is a valid id at Google/OpenAI and still
# `ModelNotFoundError` for RubyLLM (2026-09-04, account 3: `gemini-3.1-flash-lite`
# turned every customer message into the generic fallback reply without a
# single provider call). RubyLLM already supports that case via
# `assume_exists: true`, but only when the provider is known — which is
# exactly what the thread provider supplies.
require 'ruby_llm'

module RubyLLM
  THREAD_CONTEXT_KEY = :ruby_llm_thread_context
  THREAD_PROVIDER_KEY = :ruby_llm_thread_provider

  class << self
    def thread_context
      Thread.current[THREAD_CONTEXT_KEY]
    end

    def thread_provider
      Thread.current[THREAD_PROVIDER_KEY]
    end

    # Sets the per-thread default context (and, optionally, the provider it
    # routes to) for the duration of the block, restoring the previous values
    # afterwards. Nil context is a no-op.
    def with_thread_context(context, provider: nil)
      return yield if context.nil?

      previous = Thread.current[THREAD_CONTEXT_KEY]
      previous_provider = Thread.current[THREAD_PROVIDER_KEY]
      Thread.current[THREAD_CONTEXT_KEY] = context
      Thread.current[THREAD_PROVIDER_KEY] = provider.to_s.presence
      begin
        yield
      ensure
        Thread.current[THREAD_CONTEXT_KEY] = previous
        Thread.current[THREAD_PROVIDER_KEY] = previous_provider
      end
    end
  end

  module ChatThreadContext
    def initialize(model: nil, provider: nil, assume_model_exists: false, context: nil)
      context ||= RubyLLM.thread_context
      super
    end

    # Chat#initialize and every later model switch (the ai-agents runner calls
    # #with_model again when it hands off to a scenario agent) funnel through
    # here. A slug the static registry does not know is retried as an
    # assumed-existing model of the thread provider, so a model the provider
    # serves but RubyLLM has not catalogued yet still works.
    def with_model(model_id, provider: nil, assume_exists: false)
      super
    rescue RubyLLM::ModelNotFoundError => e
      fallback_provider = RubyLLM.thread_provider
      raise if provider || assume_exists || fallback_provider.nil?

      RubyLLM.logger.warn(
        "[RubyLLM] #{e.message}; assuming it exists for provider '#{fallback_provider}' (thread provider)"
      )
      super(model_id, provider: fallback_provider, assume_exists: true)
    end
  end

  class Chat
    prepend ChatThreadContext
  end
end
