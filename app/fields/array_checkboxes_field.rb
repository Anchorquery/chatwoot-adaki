require 'administrate/field/base'

# Edits a Postgres array column as a list of checkboxes. Pass the allowed
# values with `with_options(collection: [...])`.
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

  def to_s
    Array(data).join(', ')
  end
end
