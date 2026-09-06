# Turns a conversation's message thread into the message-hash array
# (`{ content:, role:, agent_name: }`) that both Captain runtimes (V1's
# AssistantChatService and V2's AgentRunnerService) expect as LLM context.
# Shared by Captain::Conversation::ResponseBuilderJob for both paths.
class Captain::Conversation::HistoryBuilder
  # Per-message cap (characters), independent of the message-count window
  # below — a single very long message (a pasted log, a forwarded document)
  # can still blow the context on its own.
  MAX_MESSAGE_LENGTH = 10_000

  # Marks a historical message that was sent by a human agent (not Captain
  # itself) so the LLM never mistakes it for something the assistant said.
  # Plain text, not a `system` role: Captain::ChatHelper merges every
  # `system`-role entry into one instructions blob ahead of the conversation,
  # which would destroy the turn-by-turn ordering this needs to preserve.
  HUMAN_AGENT_MESSAGE_PREFIX = '[Mensaje de un agente humano, no del asistente]: '.freeze

  # How long a V2 scenario agent stays "current" after its last reply. See
  # #agent_tag_still_current?.
  AGENT_STICKINESS_WINDOW = 1.hour

  # Only the most recent messages keep their image parts. Every image in the
  # window is re-fetched and re-sent on EVERY turn (RubyLLM downloads URL
  # attachments and inlines them as base64 for Gemini; OpenAI fetches the
  # URL itself), so a WhatsApp thread with a few photos paid that download
  # and upload again for each new "hola". Older images become a text
  # placeholder — the model still knows a photo was sent, and the bot's own
  # reply about it is in the history anyway.
  RECENT_IMAGE_MESSAGES = 4
  OLDER_IMAGE_PLACEHOLDER = '[imagen adjunta]'.freeze

  def initialize(conversation:, assistant:)
    @conversation = conversation
    @assistant = assistant
  end

  # Bounded to the assistant's configured window (see
  # Captain::Assistant#history_window_messages_value) — an unbounded history
  # grows the prompt without limit for long-lived conversations, until a
  # request eventually fails with a context-length error that the caller
  # (correctly, but confusingly) treats as a handoff-worthy failure.
  # Fetched newest-first so LIMIT keeps the *recent* tail, then reversed back
  # to chronological order for the LLM.
  #
  # reorder (not order!): Message has `default_scope { order(created_at:
  # :asc) }` — a plain .order(created_at: :desc) is APPENDED after that
  # default order instead of replacing it, so the generated SQL becomes
  # `ORDER BY created_at ASC, created_at DESC, id DESC` and the ASC from the
  # default scope wins (ties broken by our desc clauses, but the overall
  # direction never flips). #reorder replaces the default scope's order
  # instead of appending to it. `id: :desc` alongside created_at: two
  # messages can share the same timestamp, and Postgres doesn't guarantee
  # any order among ties on created_at alone — without `id` as a
  # tiebreaker, a LIMIT here could drop the actual most-recent messages in
  # favor of older ones that happen to tie, or scramble the order the
  # reverse below assumes is chronological. Caught by running this spec
  # against a real Postgres for the first time this session (2026-08-28) —
  # every multi-message HistoryBuilder example was silently returning
  # messages in the wrong order (or the wrong messages entirely, under
  # LIMIT) prior to this fix.
  def call
    messages = @conversation
               .messages
               .where(message_type: [:incoming, :outgoing])
               .where(private: false)
               .reorder(created_at: :desc, id: :desc)
               .limit(@assistant.history_window_messages_value(channel_type: @conversation.inbox&.channel_type))
               .to_a
               .reverse
    recent_from = [messages.size - RECENT_IMAGE_MESSAGES, 0].max
    messages.each_with_index.map { |message, index| message_hash_for(message, keep_images: index >= recent_from) }
  end

  private

  def message_hash_for(message, keep_images: true)
    message_hash = {
      content: message_content_for_llm(message, keep_images: keep_images),
      role: determine_role(message)
    }

    # agent_name tracks which Captain sub-agent (V2 multi-agent handoffs)
    # produced a given reply — meaningless, and never set, for a human reply.
    if bot_authored?(message) && agent_tag_still_current?(message) && message.additional_attributes&.dig('agent_name').present?
      message_hash[:agent_name] = message.additional_attributes['agent_name']
    end

    message_hash
  end

  def determine_role(message)
    return 'user' if message.message_type == 'incoming'
    return 'assistant' if bot_authored?(message)

    # A human agent's own reply is not something the assistant said. There is
    # no third role in the chat-completion protocol these providers speak, so
    # it goes in as 'user' with a marker prefix (see message_content_for_llm)
    # rather than silently being attributed to the assistant.
    'user'
  end

  def bot_authored?(message)
    message.sender_type == 'Captain::Assistant'
  end

  # The ai-agents runner resumes whichever sub-agent tagged the most recent
  # assistant message, with no notion of time — so a conversation handed to
  # a scenario once stayed there indefinitely (production conversation 120:
  # every bot reply from 2026-06-11 to 2026-09-04 came from the "products"
  # scenario, including its answers to "Hola" and "quiero hablar con un
  # agente"). Tags older than the window are dropped, so after that much
  # silence the next turn starts at the orchestrator again, which can
  # re-route to a scenario if it is still relevant.
  def agent_tag_still_current?(message)
    message.created_at > AGENT_STICKINESS_WINDOW.ago
  end

  def message_content_for_llm(message, keep_images: true)
    content = prepare_multimodal_message_content(message)
    content = drop_image_parts(content) unless keep_images
    prefix = HUMAN_AGENT_MESSAGE_PREFIX unless message.message_type == 'incoming' || bot_authored?(message)

    transform_text_parts(content) do |text|
      text = truncate_message_text(text)
      prefix ? "#{prefix}#{text}" : text
    end
  end

  # Replaces every image part with one text placeholder. Collapses back to a
  # plain String when nothing multimodal is left, which is the shape a
  # text-only message would have had in the first place.
  def drop_image_parts(content)
    return content unless content.is_a?(Array) && content.any? { |part| part[:type] == 'image_url' }

    texts = content.select { |part| part[:type] == 'text' }.pluck(:text)
    texts << OLDER_IMAGE_PLACEHOLDER
    texts.join("\n")
  end

  # `content` is either a String or the multimodal Array shape produced by
  # Captain::OpenAiMessageBuilderService (text/image_url parts) — transform
  # only the text, leaving image parts untouched.
  def transform_text_parts(content)
    case content
    when String
      yield(content)
    when Array
      content.map { |part| part[:type] == 'text' ? part.merge(text: yield(part[:text])) : part }
    else
      content
    end
  end

  def truncate_message_text(text)
    return text if text.length <= MAX_MESSAGE_LENGTH

    "#{text[0, MAX_MESSAGE_LENGTH]}…"
  end

  def prepare_multimodal_message_content(message)
    Captain::OpenAiMessageBuilderService.new(message: message).generate_content
  end
end
