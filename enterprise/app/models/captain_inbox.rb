# == Schema Information
#
# Table name: captain_inboxes
#
#  id                   :bigint           not null, primary key
#  settings             :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  captain_assistant_id :bigint           not null
#  inbox_id             :bigint           not null
#
# Indexes
#
#  index_captain_inboxes_on_captain_assistant_id               (captain_assistant_id)
#  index_captain_inboxes_on_captain_assistant_id_and_inbox_id  (captain_assistant_id,inbox_id) UNIQUE
#  index_captain_inboxes_on_inbox_id                           (inbox_id)
#
class CaptainInbox < ApplicationRecord
  belongs_to :captain_assistant, class_name: 'Captain::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: true

  store_accessor :settings, :auto_handoff_enabled, :auto_resolve_hours, :continue_after_human_takeover

  # Cascada: override del binding > assistant > default true.
  def continue_after_human_takeover?
    if settings.key?('continue_after_human_takeover') && !settings['continue_after_human_takeover'].nil?
      ActiveModel::Type::Boolean.new.cast(settings['continue_after_human_takeover'])
    else
      captain_assistant.continue_after_human_takeover?
    end
  end

  # Cascada: override > assistant > default false.
  def auto_handoff_enabled?
    if settings.key?('auto_handoff_enabled') && !settings['auto_handoff_enabled'].nil?
      ActiveModel::Type::Boolean.new.cast(settings['auto_handoff_enabled'])
    else
      captain_assistant.auto_handoff_enabled?
    end
  end

  # Cascada: override > assistant > 24.
  def auto_resolve_hours_value
    raw = settings['auto_resolve_hours']
    value = raw.to_i
    return value if raw.present? && value.positive?

    captain_assistant.auto_resolve_hours_value
  end
end
