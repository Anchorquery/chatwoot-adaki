# frozen_string_literal: true

# Feeds real per-provider-request wall time into [CAPTAIN][timing] (see
# docs/adaki/captain-plan-latencia-2026-09.md fases 0 and 6) via ruby_llm's
# own `request.ruby_llm` ActiveSupport::Notifications event, instead of only
# the coarser Benchmark.realtime wrapper around the whole ai-agents run
# (which also includes tool execution and gem-internal overhead).
#
# One subscriber, registered once at boot rather than per-request: the
# callback always accumulates into `Thread.current`, which at *callback*
# execution time is whichever thread actually made the HTTP request —
# ActiveSupport::Notifications invokes subscribers synchronously on that
# thread, so this is safe under Sidekiq's multi-threaded captain queue
# without any explicit thread filtering. A per-request `.subscribed` block
# would instead multiply-count: every concurrently active subscription's
# callback fires for every event.
#
# Captain::Assistant::AgentRunnerService#generate_response resets the slot to
# 0 at the start of a turn and reads it back into the timing hash at the end;
# any Captain::BaseTaskService call made synchronously during that turn (the
# fase 5.2 judge, the fase 5.3 summarizer) is real provider time spent on
# this turn's account, so it is deliberately included too.
ActiveSupport::Notifications.subscribe('request.ruby_llm') do |_name, start, finish, _id, _payload|
  Thread.current[:captain_provider_request_ms] ||= 0
  Thread.current[:captain_provider_request_ms] += (finish - start) * 1000
end
