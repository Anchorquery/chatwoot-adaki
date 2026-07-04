require 'rack-timeout'

# Routes that call LLMs and need more time than the default 15s.
SLOW_AI_ROUTES = [
  %r{/captain/assistants/\d+/generate_config\z},
  %r{/captain/assistants/\d+/playground\z},
  %r{/campaigns/ai_generate\z},
  %r{/captain/scenarios/generate\z}
].freeze

# rack-timeout 0.6.3 doesn't support per-request override. Prepend Rack::Timeout
# to bypass the timer entirely for slow LLM routes. The request still finishes
# under Puma's worker timeout (usually 60-120s).
module RackTimeoutSkipSlowRoutes
  def call(env)
    path = env['PATH_INFO'].to_s
    return @app.call(env) if SLOW_AI_ROUTES.any? { |pattern| pattern.match?(path) }

    super
  end
end
Rack::Timeout.prepend(RackTimeoutSkipSlowRoutes)
Rails.logger&.info('[SlowAiRoutes] Rack::Timeout bypass installed for LLM routes') if defined?(Rails) && Rails.logger

# Reduce noise by filtering state=ready and state=completed which are logged at INFO level
Rails.application.config.after_initialize do
  Rack::Timeout::Logger.level = Logger::ERROR
end
