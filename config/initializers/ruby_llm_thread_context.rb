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
# slug up in its static registry (config/llm_models.json): a snapshot that
# lags behind what the providers actually serve, and that can even route a
# shared id to another provider (Models::PROVIDER_PREFERENCE). Captain's
# model slugs come from the provider's live model list synced into
# Platform::CredentialModel, and that row (id + credential provider) is the
# source of truth — so while a thread provider is published the registry is
# not consulted at all: the chat is built for that provider with the id
# verbatim (`assume_exists: true`, which RubyLLM supports and which assumes
# function calling). Without this, a freshly released model was a valid id at
# Google and still `ModelNotFoundError` here (2026-09-04, account 3:
# `gemini-3.1-flash-lite` turned every customer message into the generic
# fallback reply without a single provider call).
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
    # here. With a thread provider published, the model id is taken as-is for
    # that provider and the static registry is bypassed; an explicit provider
    # or assume_exists from the caller is left untouched.
    def with_model(model_id, provider: nil, assume_exists: false)
      thread_provider = RubyLLM.thread_provider
      return super if provider || assume_exists || thread_provider.nil?

      super(model_id, provider: thread_provider, assume_exists: true)
    end
  end

  class Chat
    prepend ChatThreadContext
  end
end
