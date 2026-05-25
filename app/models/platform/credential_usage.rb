# == Schema Information
#
# Table name: platform_credential_usages
#
#  id                    :bigint           not null, primary key
#  account_id            :bigint
#  context               :jsonb            not null
#  created_at            :datetime         not null
#  error_code            :string
#  operation             :string           not null
#  platform_credential_id :bigint          not null
#  status                :string           not null
#  used_by_type          :string
#  used_by_id            :bigint
#
class Platform::CredentialUsage < ApplicationRecord
  belongs_to :account, optional: true
  belongs_to :platform_credential, class_name: 'Platform::Credential'
  belongs_to :used_by, polymorphic: true, optional: true

  validates :operation, :status, presence: true
end
