require 'rails_helper'

# See config/initializers/ruby_llm_request_instrumentation.rb and
# docs/adaki/captain-plan-latencia-2026-09.md fase 6.
RSpec.describe 'ruby_llm request instrumentation' do
  before { Thread.current[:captain_provider_request_ms] = nil }
  after { Thread.current[:captain_provider_request_ms] = nil }

  it 'accumulates the wall time of a request.ruby_llm event into Thread.current' do
    ActiveSupport::Notifications.instrument('request.ruby_llm', {}) { sleep 0.01 }

    expect(Thread.current[:captain_provider_request_ms]).to be >= 10
  end

  it 'accumulates across multiple events in the same thread instead of overwriting' do
    2.times { ActiveSupport::Notifications.instrument('request.ruby_llm', {}) { sleep 0.01 } }

    expect(Thread.current[:captain_provider_request_ms]).to be >= 20
  end

  it 'does not touch other request.* events' do
    ActiveSupport::Notifications.instrument('request.other_gem', {}) { sleep 0.01 }

    expect(Thread.current[:captain_provider_request_ms]).to be_nil
  end
end
