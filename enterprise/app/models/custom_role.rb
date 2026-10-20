# == Schema Information
#
# Table name: custom_roles
#
#  id              :bigint           not null, primary key
#  description     :string
#  name            :string
#  permissions     :text             default([]), is an Array
#  sidebar_profile :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#
# Indexes
#
#  index_custom_roles_on_account_id  (account_id)
#

# Available permissions for custom roles, grouped by the section of the app
# they open. Each one is an independent checkbox in the role form.
#
# Conversations
# - 'conversation_manage': Can manage all conversations.
# - 'conversation_unassigned_manage': Can manage unassigned conversations and assign to self.
# - 'conversation_participating_manage': Can manage conversations they are participating in (assigned to or a participant).
# - 'macro_manage': Can create, edit and delete shared (global) macros.
# Contacts (and companies)
# - 'contact_manage': Can manage contacts.
# Campaigns
# - 'campaign_manage': Can create, edit, clone and launch campaigns.
# - 'campaign_approve': Can approve or reject campaigns that need approval.
# Channels
# - 'inbox_manage': Can create, configure and delete every inbox.
# - 'channel_operate': Works with every WhatsApp number of the account: becomes a collaborator of its inboxes
#   (see CustomRoles::WhatsappInboxAccessService) and can connect (QR), check and restart their session.
# Captain
# - 'captain_manage': Can manage Captain assistants, tools and settings.
# Team
# - 'agent_manage': Can invite and manage agents.
# - 'team_manage': Can manage teams.
# - 'label_manage': Can manage labels.
# - 'assignment_manage': Can manage assignment and capacity policies.
# - 'absence_manage': Can manage agent absences.
# Customization
# - 'automation_manage': Can manage automation rules.
# - 'attribute_manage': Can manage custom attributes.
# - 'agent_bot_manage': Can manage agent bots.
# - 'sla_manage': Can manage SLA policies.
# Integrations
# - 'integration_manage': Can manage integrations and webhooks.
# Account
# - 'account_settings_manage': Can edit the general account settings.
# - 'audit_log_view': Can read the audit logs.
# Reports and help center
# - 'report_manage': Can manage reports.
# - 'knowledge_base_manage': Can manage knowledge base portals.

class CustomRole < ApplicationRecord
  belongs_to :account
  has_many :account_users, dependent: :nullify

  PERMISSION_GROUPS = {
    'conversations' => %w[
      conversation_manage
      conversation_unassigned_manage
      conversation_participating_manage
      macro_manage
    ],
    'contacts' => %w[contact_manage],
    'campaigns' => %w[campaign_manage campaign_approve],
    'channels' => %w[inbox_manage channel_operate],
    'captain' => %w[captain_manage],
    'team' => %w[agent_manage team_manage label_manage assignment_manage absence_manage],
    'customization' => %w[automation_manage attribute_manage agent_bot_manage sla_manage],
    'integrations' => %w[integration_manage],
    'reports' => %w[report_manage],
    'knowledge_base' => %w[knowledge_base_manage],
    'account' => %w[account_settings_manage audit_log_view]
  }.freeze

  PERMISSIONS = PERMISSION_GROUPS.values.flatten.freeze

  # Older roles may still carry this single permission that used to open
  # every team/inbox/label setting at once. It is expanded to the granular
  # ones when permissions are resolved.
  LEGACY_PERMISSIONS = {
    'agent_settings_manage' => %w[inbox_manage agent_manage team_manage label_manage assignment_manage]
  }.freeze

  # Ready-made sets of permissions the role form can apply with one click.
  PRESETS = {
    'ai_agent' => %w[
      conversation_manage
      captain_manage
      inbox_manage
      agent_manage
      team_manage
      label_manage
      assignment_manage
    ],
    'communication' => %w[conversation_manage contact_manage campaign_manage channel_operate]
  }.freeze

  # Roles created before the permission matrix picked one of these presets
  # instead of ticking boxes; kept so those rows still resolve.
  SIDEBAR_PROFILES = PRESETS.keys.freeze

  validates :name, presence: true
  validates :permissions, inclusion: { in: PERMISSIONS + LEGACY_PERMISSIONS.keys }
  validates :sidebar_profile, inclusion: { in: SIDEBAR_PROFILES }, allow_nil: true

  after_commit :grant_whatsapp_inboxes, on: :update, if: :saved_change_to_permissions?

  def profile_permissions
    PRESETS.fetch(sidebar_profile, [])
  end

  # What the role actually grants: ticked permissions, the legacy preset it may
  # still carry, and the granular permissions a legacy one stands for.
  def effective_permissions
    granted = (permissions + profile_permissions).uniq
    granted | LEGACY_PERMISSIONS.slice(*granted).values.flatten
  end

  private

  def grant_whatsapp_inboxes
    account_users.includes(:custom_role).find_each do |account_user|
      CustomRoles::WhatsappInboxAccessService.grant_for_account_user(account_user)
    end
  end
end
