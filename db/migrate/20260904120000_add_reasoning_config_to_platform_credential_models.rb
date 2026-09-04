class AddReasoningConfigToPlatformCredentialModels < ActiveRecord::Migration[7.1]
  # Per-model reasoning capabilities, in the OpenRouter shape:
  #   { "supported_efforts" => ["none", "low", ...], "source" => "seed|provider|manual", ... }
  # Seeded by family on import, corrected from provider rejections, editable in
  # the providers view. See Llm::ReasoningCapabilities.
  def change
    add_column :platform_credential_models, :reasoning_config, :jsonb, null: false, default: {}
  end
end
