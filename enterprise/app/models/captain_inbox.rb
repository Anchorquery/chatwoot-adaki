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

  store_accessor :settings, :auto_handoff_enabled, :auto_resolve_hours, :continue_after_human_takeover,
                 :human_takeover_mode, :human_takeover_window_minutes, :service_contact_numbers,
                 :handoff_team_id

  # Cascada: override > assistant > nil (sin equipo: auto-asignación del inbox).
  # Un override explícito a 0 significa "sin equipo" aunque el asistente
  # tenga uno; la clave ausente significa heredar.
  def handoff_team_id_value
    if settings.key?('handoff_team_id') && !settings['handoff_team_id'].nil?
      value = settings['handoff_team_id'].to_i
      return value.positive? ? value : nil
    end

    value = captain_assistant.config['handoff_team_id'].to_i
    value.positive? ? value : nil
  end

  def handoff_team
    team_id = handoff_team_id_value
    return nil if team_id.nil?

    captain_assistant.account.teams.find_by(id: team_id)
  end

  # Cascade: override > default. No assistant-level fallback — this is a
  # channel/provider concern, not an assistant behavior setting. The default
  # lives on Conversation (FOSS), not here, so it stays resolvable in the
  # stripped FOSS CI build that never loads this (enterprise-only) class.
  def service_contact_numbers_value
    raw = settings['service_contact_numbers']
    return raw if raw.is_a?(Array) && raw.present?

    Conversation::DEFAULT_SERVICE_CONTACT_NUMBERS
  end

  # Cascada: override del binding > assistant > default true.
  def continue_after_human_takeover?
    if settings.key?('continue_after_human_takeover') && !settings['continue_after_human_takeover'].nil?
      ActiveModel::Type::Boolean.new.cast(settings['continue_after_human_takeover'])
    else
      captain_assistant.continue_after_human_takeover?
    end
  end

  # Cascada: override > assistant > default (after_window).
  def human_takeover_mode_value
    raw = settings['human_takeover_mode']
    return raw if Captain::Assistant::HUMAN_TAKEOVER_MODES.include?(raw)

    captain_assistant.human_takeover_mode_value
  end

  # Cascada: override > assistant > default 15.
  def human_takeover_window_minutes_value
    raw = settings['human_takeover_window_minutes']
    value = raw.to_i
    return value if raw.present? && value.positive?

    captain_assistant.human_takeover_window_minutes_value
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
