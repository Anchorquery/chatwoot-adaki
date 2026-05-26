require 'rack-timeout'

# Routes that call LLMs and need more time than the default 15s.
SLOW_AI_ROUTES = [
  %r{/captain/assistants/\d+/generate_config\z},
  %r{/campaigns/ai_generate\z}
].freeze

# Per-request override of rack-timeout's service-timeout. Runs before
# Rack::Timeout starts its timer so the new value is honored.
class SlowAiRouteTimeout
  SERVICE_TIMEOUT_SECONDS = 60

  def initialize(app)
    @app = app
  end

  def call(env)
    if SLOW_AI_ROUTES.any? { |pattern| pattern.match?(env['PATH_INFO']) }
      env['rack-timeout.service-timeout'] = SERVICE_TIMEOUT_SECONDS
    end
    @app.call(env)
  end
end

Rails.application.config.middleware.insert_before Rack::Timeout, SlowAiRouteTimeout

# Reduce noise by filtering state=ready and state=completed which are logged at INFO level
Rails.application.config.after_initialize do
  Rack::Timeout::Logger.level = Logger::ERROR
end
