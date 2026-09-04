# == Schema Information
#
# Table name: captain_assistants
#
#  id                  :bigint           not null, primary key
#  config              :jsonb            not null
#  description         :string
#  guardrails          :jsonb
#  name                :string           not null
#  response_guidelines :jsonb
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#
# Indexes
#
#  index_captain_assistants_on_account_id  (account_id)
#
class Captain::Assistant < ApplicationRecord
  include Avatarable
  include Concerns::CaptainToolsHelpers
  include Concerns::Agentable

  self.table_name = 'captain_assistants'

  belongs_to :account
  has_many :documents, class_name: 'Captain::Document', dependent: :destroy_async
  has_many :responses, class_name: 'Captain::AssistantResponse', dependent: :destroy_async
  has_many :captain_inboxes,
           class_name: 'CaptainInbox',
           foreign_key: :captain_assistant_id,
           dependent: :destroy_async
  has_many :inboxes,
           through: :captain_inboxes
  has_many :captain_inbox_audiences,
           foreign_key: :captain_assistant_id,
           dependent: :destroy_async
  has_many :messages, as: :sender, dependent: :nullify
  has_many :copilot_threads, dependent: :destroy_async
  has_many :scenarios, class_name: 'Captain::Scenario', dependent: :destroy_async

  HUMAN_TAKEOVER_MODES = %w[always after_window never].freeze
  DEFAULT_HUMAN_TAKEOVER_MODE = 'after_window'
  DEFAULT_HUMAN_TAKEOVER_WINDOW_MINUTES = 15

  # Cap on how many recent conversation messages are sent to the LLM as context.
  # Unbounded history was the actual cause behind some "Captain se pega"
  # reports: a long-lived conversation grows its prompt without limit until a
  # request eventually fails with a context-length error, which the job then
  # (incorrectly) treats as a handoff-worthy failure.
  DEFAULT_HISTORY_WINDOW_MESSAGES = 30

  store_accessor :config, :temperature, :feature_faq, :feature_memory, :feature_contact_attributes,
                 :product_name, :autopilot_enabled, :group_trigger, :whatsapp_number,
                 :auto_handoff_enabled, :auto_resolve_hours, :continue_after_human_takeover,
                 :human_takeover_mode, :human_takeover_window_minutes, :history_window_messages,
                 :handoff_team_id, :reasoning_level

  validates :name, presence: true
  validates :description, presence: true
  validates :account_id, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  scope :for_account, ->(account_id) { where(account_id: account_id) }

  def available_name
    name
  end

  def autopilot_enabled?
    ActiveModel::Type::Boolean.new.cast(config['autopilot_enabled'])
  end

  # Cuánto puede "pensar" el modelo antes de responder (ver Llm::Thinking).
  # Default 'off': para un bot de soporte que consulta FAQs y enruta a
  # escenarios, el razonamiento interno solo añade latencia, coste y el
  # fallo de respuesta vacía del incidente del 2026-09-04.
  def reasoning_level_value
    Llm::Thinking.normalize_level(config['reasoning_level'])
  end

  # Equipo al que se enruta un handoff bot → humano (ver
  # Enterprise::Conversation#bot_handoff!). Nil = sin equipo: auto-asignación
  # entre todos los miembros del inbox. Un id que ya no existe en la cuenta
  # cuenta como nil, no como error.
  def handoff_team
    team_id = config['handoff_team_id'].to_i
    return nil unless team_id.positive?

    account.teams.find_by(id: team_id)
  end

  # Default true: bot retoma conversación aunque exista assignee o respuesta humana previa.
  def continue_after_human_takeover?
    return true unless config.key?('continue_after_human_takeover')

    ActiveModel::Type::Boolean.new.cast(config['continue_after_human_takeover'])
  end

  # Default false: desactiva cron de auto-handoff por evaluación LLM.
  def auto_handoff_enabled?
    ActiveModel::Type::Boolean.new.cast(config['auto_handoff_enabled'])
  end

  # Default 24h: ventana de inactividad antes de evaluar auto-resolve/handoff.
  def auto_resolve_hours_value
    value = config['auto_resolve_hours'].to_i
    value.positive? ? value : 24
  end

  # Modo de re-enganche del bot tras intervención humana.
  # always: bot siempre puede responder.
  # after_window: bot retoma si última respuesta humana fue hace > N minutos.
  # never: humano queda dueño de la conversación.
  def human_takeover_mode_value
    raw = config['human_takeover_mode']
    return raw if HUMAN_TAKEOVER_MODES.include?(raw)

    # Compat: si toggle legacy off, bot nunca retoma → equivalente a windows=∞.
    # Si toggle legacy on (default), usamos default nuevo.
    return 'never' if config.key?('continue_after_human_takeover') &&
                      !ActiveModel::Type::Boolean.new.cast(config['continue_after_human_takeover'])

    DEFAULT_HUMAN_TAKEOVER_MODE
  end

  def human_takeover_window_minutes_value
    value = config['human_takeover_window_minutes'].to_i
    value.positive? ? value : DEFAULT_HUMAN_TAKEOVER_WINDOW_MINUTES
  end

  # How many recent messages to include as LLM context. See
  # DEFAULT_HISTORY_WINDOW_MESSAGES.
  def history_window_messages_value
    value = config['history_window_messages'].to_i
    value.positive? ? value : DEFAULT_HISTORY_WINDOW_MESSAGES
  end

  def available_agent_tools
    Captain::Tools::RegistryService.new(account: account, assistant: self).available_tool_metadata
  end

  def available_tool_ids
    available_agent_tools.map { |tool| tool[:id] }
  end

  def push_event_data
    {
      id: id,
      name: name,
      avatar_url: avatar_url.presence || default_avatar_url,
      description: description,
      created_at: created_at,
      type: 'captain_assistant'
    }
  end

  def webhook_data
    {
      id: id,
      name: name,
      avatar_url: avatar_url.presence || default_avatar_url,
      description: description,
      created_at: created_at,
      type: 'captain_assistant'
    }
  end

  private

  def agent_name
    name.parameterize(separator: '_')
  end

  def agent_tools
    Captain::Tools::RegistryService.new(account: account, assistant: self).assistant_tools
  end

  def prompt_context
    {
      name: name,
      description: description,
      product_name: config['product_name'] || 'this product',
      scenarios: scenarios.enabled.map do |scenario|
        {
          title: scenario.title,
          key: scenario.handoff_key,
          description: scenario.description
        }
      end,
      response_guidelines: response_guidelines || [],
      guardrails: guardrails || []
    }
  end

  def default_avatar_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/assets/images/dashboard/captain/logo.svg"
  end
end
