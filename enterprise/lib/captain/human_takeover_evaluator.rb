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
      return true if captain_handoff_pending?
      return false unless assignee_present? || human_response_exists?
      return false if bot_can_takeover?

      true
    end

    # Captain se apartó por sí mismo (HandoffTool o process_v1_handoff →
    # Conversation#bot_handoff!) y ningún humano ha recogido la conversación
    # desde entonces. Sin esto, en el modo Adaki "el bot responde en open"
    # un handoff era invisible: la conversación ya estaba abierta y el
    # siguiente mensaje del cliente devolvía el bot (conv 120, 2026-09-04).
    # La marca deja de contar cuando un humano responde después de ella
    # (a partir de ahí aplican las reglas normales de modo), cuando la
    # conversación se resolvió después de ella (una reapertura posterior
    # empieza de cero), o cuando expira la gracia del modo configurado.
    def captain_handoff_pending?
      handoff_at = conversation.respond_to?(:captain_handoff_at) ? conversation.captain_handoff_at : nil
      return false if handoff_at.blank?
      return false if human_response_since?(handoff_at)
      return false if resolved_since?(handoff_at)

      !handoff_grace_expired?(handoff_at)
    end

    # Cuánto calla el bot tras un handoff que nadie ha recogido. Sin esta
    # caducidad, un handoff que no llegó a asignarse a nadie (ningún agente
    # online, o ningún colaborador en la bandeja) dejaba la conversación en
    # silencio permanente: el cliente escribía y no contestaba ni el bot ni
    # un humano (conv 309, 2026-09-04 03:08). Se reutiliza la misma ventana
    # de re-enganche que el operador ya configuró para las respuestas
    # humanas, porque la pregunta es idéntica: cuánto esperamos a que un
    # humano se haga cargo antes de que el bot siga ayudando.
    def handoff_grace_expired?(handoff_at)
      case mode
      when 'always' then true
      when 'never' then false
      else handoff_at < window_minutes.minutes.ago
      end
    end

    private

    attr_reader :conversation, :inbox

    def human_response_since?(time)
      conversation.messages
                  .outgoing
                  .where(private: false, sender_type: 'User')
                  .exists?(['created_at > ?', time])
    end

    def resolved_since?(time)
      ReportingEvent.where(conversation_id: conversation.id, name: 'conversation_resolved')
                    .exists?(['created_at > ?', time])
    end

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
      # ts blank here means an agent is assigned but hasn't replied yet (the
      # `assignee_present? || human_response_exists?` guard in #human_takeover?
      # already ruled out the "no signal at all" case). Treat that as freshly
      # taken over rather than stale, so a bare assignment silences the bot.
      return false if ts.blank?

      ts < window_minutes.minutes.ago
    end
  end
end
