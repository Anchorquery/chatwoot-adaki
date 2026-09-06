# == Schema Information
#
# Table name: platform_credential_models
#
#  id                       :bigint           not null, primary key
#  credential_id            :bigint           not null
#  slug                     :string           not null
#  display_name             :string           not null
#  kind                     :string           not null, default("chat")
#  capabilities             :jsonb            not null, default([])
#  context_window           :integer
#  max_output_tokens        :integer
#  input_price_per_million  :decimal(12,4)
#  output_price_per_million :decimal(12,4)
#  data_cutoff_at           :date
#  description              :text
#  obsolete                 :boolean          default(false), not null
#  enabled                  :boolean          default(false), not null
#  raw_metadata             :jsonb            not null, default({})
#  synced_at                :datetime
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
class Platform::CredentialModel < ApplicationRecord
  self.table_name = 'platform_credential_models'

  KINDS = %w[chat multimodal embedding image tts realtime transcription video web_search].freeze
  CAPABILITIES = %w[multimodal image_gen embedding transcription tts video_gen web_search tools thinking code json vision].freeze

  belongs_to :credential, class_name: '::Platform::Credential'

  validates :slug, presence: true, uniqueness: { scope: :credential_id }
  validates :display_name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validate :reasoning_config_shape

  scope :enabled, -> { where(enabled: true) }
  scope :by_kind, ->(kind) { where(kind: kind) }

  # Efforts this model accepts per its own row (see Llm::ReasoningCapabilities);
  # nil when nothing is recorded yet.
  def reasoning_supported_efforts
    Llm::ReasoningCapabilities.stored_efforts(reasoning_config)
  end

  private

  def reasoning_config_shape
    return if reasoning_config.blank?
    return errors.add(:reasoning_config, 'must be an object') unless reasoning_config.is_a?(Hash)

    efforts = reasoning_config['supported_efforts']
    return if efforts.nil?
    return if efforts.is_a?(Array) && (efforts.map(&:to_s) - Llm::ReasoningCapabilities::EFFORTS).empty?

    errors.add(:reasoning_config, "supported_efforts must be a subset of #{Llm::ReasoningCapabilities::EFFORTS.join(', ')}")
  end
end
