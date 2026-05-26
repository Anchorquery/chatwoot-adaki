require 'rack-timeout'

# rack-timeout 0.6.3 reads service_timeout once at init (no per-request env
# override). Patch service_timeout to allow per-request override stored in
# Thread.current — each Puma worker thread serves one request at a time, so
# thread-local is request-scoped and safe.
module RackTimeoutPerRequestOverride
  def service_timeout
    Thread.current[:rack_timeout_service_override] || super
  end
end
Rack::Timeout.prepend(RackTimeoutPerRequestOverride)

# Routes that call LLMs and need more time than the default 15s.
SLOW_AI_ROUTES = [
  %r{/captain/assistants/\d+/generate_config\z},
  %r{/campaigns/ai_generate\z}
].freeze

# Middleware inserted BEFORE Rack::Timeout. Sets thread-local override that
# the patched service_timeout method reads.
class SlowAiRouteTimeout
  SERVICE_TIMEOUT_SECONDS = 60

  def initialize(app)
    @app = app
  end

  def call(env)
    slow = SLOW_AI_ROUTES.any? { |pattern| pattern.match?(env['PATH_INFO']) }
    Thread.current[:rack_timeout_service_override] = SERVICE_TIMEOUT_SECONDS if slow
    @app.call(env)
  ensure
    Thread.current[:rack_timeout_service_override] = nil if slow
  end
end

Rails.application.config.middleware.insert_before Rack::Timeout, SlowAiRouteTimeout

# Reduce noise by filtering state=ready and state=completed which are logged at INFO level
Rails.application.config.after_initialize do
  Rack::Timeout::Logger.level = Logger::ERROR
end
