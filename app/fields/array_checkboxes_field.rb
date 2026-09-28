require 'administrate/field/base'

# Edits a Postgres array column as a list of checkboxes. Pass the allowed
# values with `with_options(collection: [...])` and, optionally, an
# `i18n_scope:` under which each value has a human label.
class ArrayCheckboxesField < Administrate::Field::Base
  def self.permitted_attribute(attribute, _options = nil)
    { attribute => [] }
  end

  def collection
    options.fetch(:collection, [])
  end

  def selected?(value)
    Array(data).include?(value)
  end

  def label_for(value)
    scope = options[:i18n_scope]
    return value.to_s.humanize unless scope

    I18n.t("#{scope}.#{value}", default: value.to_s.humanize)
  end

  def to_s
    Array(data).map { |value| label_for(value) }.join(', ')
  end
end
