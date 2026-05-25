# == Schema Information
#
# Table name: platform_credentials
#
#  id                  :bigint           not null, primary key
#  account_id          :bigint
#  auth_type           :string           not null
#  encrypted_payload   :jsonb            not null
#  expires_at          :datetime
#  key                 :string           not null
#  last_used_at        :datetime
#  last_validated_at   :datetime
#  metadata            :jsonb            not null
#  name                :string           not null
#  owner_type          :string
#  owner_id            :bigint
#  purpose             :string           not null
#  provider            :string           not null
#  status              :integer          default(0), not null
#  created_by_id       :bigint
#  updated_by_id       :bigint
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
class Platform::Credential < ApplicationRecord
  belongs_to :account, optional: true
  belongs_to :owner, polymorphic: true, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true
  has_many :platform_credential_usages, dependent: :destroy_async, class_name: '::Platform::CredentialUsage'

  encrypts :encrypted_payload if Chatwoot.encryption_configured?

  enum status: { active: 0, invalid: 1, expired: 2, revoked: 3 }, _prefix: :status
  enum auth_type: {
    api_key: 'api_key',
    bearer: 'bearer',
    basic: 'basic',
    oauth2: 'oauth2',
    custom_json: 'custom_json'
  }, _prefix: :auth

  validates :provider, :purpose, :name, :key, :auth_type, presence: true
  validates :key, uniqueness: { scope: :account_id }
  validates :encrypted_payload, presence: true

  scope :active, -> { where(status: :active) }
  scope :for_account, ->(account) { where(account: account) }

  def payload
    encrypted_payload.with_indifferent_access
  end

  def payload=(value)
    self.encrypted_payload = (value || {}).with_indifferent_access
  end

  def secret(name)
    payload[name.to_s]
  end

  def token_hint
    metadata['token_hint']
  end
end
