# Sidebar profiles were fixed bundles of permissions with their own hard-coded
# menu. The role form now ticks permissions per section, so each existing
# profile becomes the explicit permissions it stood for (and the legacy
# "agent_settings_manage" becomes its granular parts).
class ConvertCustomRoleSidebarProfilesToPermissions < ActiveRecord::Migration[7.1]
  PRESETS = {
    'ai_agent' => %w[conversation_manage captain_manage inbox_manage agent_manage team_manage label_manage assignment_manage],
    'communication' => %w[conversation_manage contact_manage campaign_manage channel_operate]
  }.freeze
  LEGACY = { 'agent_settings_manage' => %w[inbox_manage agent_manage team_manage label_manage assignment_manage] }.freeze

  def up
    roles = Class.new(ApplicationRecord) { self.table_name = 'custom_roles' }
    roles.reset_column_information
    roles.find_each do |role|
      granted = (Array(role.permissions) + PRESETS.fetch(role.sidebar_profile.to_s, [])).uniq
      granted = (granted - LEGACY.keys) | LEGACY.slice(*granted).values.flatten
      next if granted == Array(role.permissions) && role.sidebar_profile.nil?

      role.update_columns(permissions: granted, sidebar_profile: nil) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    # The previous profiles cannot be told apart from hand-picked permissions.
  end
end
