require 'administrate/field/base'

# Edits a Postgres array column as a list of checkboxes. Pass the allowed
# values with `with_options(collection: [...])` and, optionally, an
# `i18n_scope:` under which each value has a human label.
#
# For a long list, `groups:` ({ 'section' => [values] }) draws one titled box
# per section (titles live under `<i18n_scope>_groups.<section>`), and
# `presets:` ({ 'name' => [values] }) adds one-click buttons that tick a ready
# made set (names live under `<i18n_scope>_presets.<name>`).
class ArrayCheckboxesField < Administrate::Field::Base
  def self.permitted_attribute(attribute, _options = nil)
    { attribute => [] }
  end

  def collection
    options.fetch(:collection, [])
  end

  def groups
    options[:groups].presence || { nil => collection }
  end

  def presets
    options.fetch(:presets, {})
  end

  def selected?(value)
    Array(data).include?(value)
  end

  def label_for(value)
    translate(options[:i18n_scope], value)
  end

  def group_label(group)
    return if group.blank? || options[:i18n_scope].blank?

    translate("#{options[:i18n_scope]}_groups", group)
  end

  def preset_label(preset)
    return preset.to_s.humanize if options[:i18n_scope].blank?

    translate("#{options[:i18n_scope]}_presets", preset)
  end

  def to_s
    Array(data).map { |value| label_for(value) }.join(', ')
  end

  private

  def translate(scope, value)
    return value.to_s.humanize unless scope

    I18n.t("#{scope}.#{value}", default: value.to_s.humanize)
  end
end
