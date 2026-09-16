# Pre-routes a turn straight to the best-matching scenario agent by comparing
# the customer's message against each scenario's embedding (title +
# description), instead of always paying for an orchestrator call +
# `handoff_to_*` first. See docs/adaki/captain-plan-latencia-2026-09.md
# fase 4.1 — same technique Captain::KnowledgePrefetcher already uses for
# FAQs, applied to scenario selection.
#
# Deliberately conservative: a false negative (no match) just falls through
# to the normal orchestrator/stickiness routing that runs today. A false
# positive starts the whole turn in the wrong scenario, so the default
# threshold favors precision over recall — tighter than the FAQ prefetch's.
class Captain::Conversation::ScenarioRouter
  # "hola", "gracias", "sí" carry nothing worth embedding or routing on.
  MIN_QUERY_WORDS = 2
  MAX_QUERY_LENGTH = 1_000
  DEFAULT_DISTANCE_THRESHOLD = 0.55

  def initialize(assistant)
    @assistant = assistant
  end

  # @param query [String, nil] plain text of the latest customer message
  # @return [Captain::Scenario, nil] the best match, or nil when nothing
  #   clears the threshold (or there is nothing to embed against)
  def route(query)
    text = normalize(query)
    return nil if text.nil?

    scenarios = @assistant.scenarios.enabled.where.not(embedding: nil)
    return nil if scenarios.none?

    match = nearest_scenario(scenarios, text)
    return nil if match.nil? || match.neighbor_distance > distance_threshold

    Rails.logger.info(
      "[CAPTAIN][preroute] assistant=#{@assistant.id} scenario=#{match.handoff_key} " \
      "distance=#{match.neighbor_distance.round(3)}"
    )
    match
  rescue StandardError => e
    Rails.logger.warn("[Captain V2] scenario pre-route skipped: #{e.class}: #{e.message}")
    nil
  end

  private

  def nearest_scenario(scenarios, text)
    embedding = Captain::Llm::EmbeddingService.new(account: @assistant.account, purpose: :search).get_embedding(text)
    return nil if embedding.blank?

    scope = Captain::Embeddings::Manager.scope_to_active(scenarios, @assistant.account)
    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').first
  end

  def normalize(query)
    text = query.to_s.strip
    return nil if text.blank? || text.split.size < MIN_QUERY_WORDS

    text.first(MAX_QUERY_LENGTH)
  end

  def distance_threshold
    ENV.fetch('CAPTAIN_SCENARIO_PREROUTE_DISTANCE_THRESHOLD', DEFAULT_DISTANCE_THRESHOLD).to_f
  end
end
