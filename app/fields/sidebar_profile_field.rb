require 'administrate/field/base'

# Sidebar profile picker for custom roles. A plain select (not
# Field::Select, whose selectize widget drops the blank option and
# preselects the first profile) with an explicit "default sidebar" choice
# and human labels.
class SidebarProfileField < Administrate::Field::Base
  I18N_SCOPE = 'super_admin.custom_roles.sidebar_profiles'.freeze

  def self.label_for(profile)
    return I18n.t("#{I18N_SCOPE}.none") if profile.blank?

    I18n.t("#{I18N_SCOPE}.#{profile}", default: profile.to_s.humanize)
  end

  def select_options
    [[self.class.label_for(nil), '']] +
      options.fetch(:collection, []).map { |profile| [self.class.label_for(profile), profile] }
  end

  def to_s
    self.class.label_for(data)
  end
end
