module Captain
  # Decide si bot puede responder dado el modo configurado por inbox/asistente.
  # Centraliza lógica usada por MessageTemplates::HookExecutionService y
  # Captain::Conversation::ResponseBuilderJob para evitar divergencia.
  #
  # Modos:
  #   always       - bot siempre puede responder aunque haya humano.
  #   after_window - bot retoma si última respuesta humana fue hace > N minutos.
  #   never        - bot cede a humano siempre tras intervención.
  class HumanTakeoverEvaluator
    def initialize(conversation:)
      @conversation = conversation
      @inbox = conversation.inbox
    end

    # true si el bot debe ceder a humano (NO responder).
    def human_takeover?
      return false unless assignee_present? || human_response_exists?
      return false if bot_can_takeover?

      true
    end

    private

    attr_reader :conversation, :inbox

    def assignee_present?
      conversation.assignee_id.present?
    end

    def human_response_exists?
      conversation.messages
                  .outgoing
                  .where(private: false)
                  .where(sender_type: 'User')
                  .exists?
    end

    def bot_can_takeover?
      case mode
      when 'always'
        true
      when 'after_window'
        last_human_response_older_than_window?
      else # 'never' o desconocido
        false
      end
    end

    def mode
      captain_inbox&.human_takeover_mode_value
    end

    def window_minutes
      captain_inbox&.human_takeover_window_minutes_value || Captain::Assistant::DEFAULT_HUMAN_TAKEOVER_WINDOW_MINUTES
    end

    def captain_inbox
      return @captain_inbox if defined?(@captain_inbox)

      @captain_inbox = inbox.respond_to?(:captain_inbox) ? inbox.captain_inbox : nil
    end

    def last_human_response_at
      conversation.messages
                  .outgoing
                  .where(private: false)
                  .where(sender_type: 'User')
                  .maximum(:created_at)
    end

    def last_human_response_older_than_window?
      ts = last_human_response_at
      return true if ts.blank?

      ts < window_minutes.minutes.ago
    end
  end
end
