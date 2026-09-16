# Lets Captain pre-route a turn straight to the matching scenario agent by
# comparing the customer's message against each scenario's title+description,
# instead of always paying for an orchestrator call first. See
# docs/adaki/captain-plan-latencia-2026-09.md fase 4.1.
class AddEmbeddingToCaptainScenarios < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_scenarios, :embedding, :vector, limit: 1536
    add_column :captain_scenarios, :embedding_model, :string
    # No ivfflat index: a handful of scenarios per assistant (plan puts Puntua
    # at 16) is nowhere near where an approximate index pays for itself over a
    # plain sequential scan — see captain-latencia.md's note on the same
    # tradeoff for FAQs.
    add_index :captain_scenarios, :embedding_model
  end
end
