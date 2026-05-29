class Captain::Copilot::ChatService < Llm::BaseAiService
  include Captain::ChatHelper

  attr_reader :assistant, :account, :user, :copilot_thread, :previous_history, :messages

  def initialize(assistant, config)
    super()

    @assistant = assistant
    @account = assistant.account
    @user = nil
    @copilot_thread = nil
    @previous_history = []
    @conversation = @account.conversations.find_by(display_id: config[:conversation_id])
    @conversation_id = @conversation&.display_id

    # Re-resolve model now that @account is set so Platform::Models::Resolver
    # can honor the credential/model toggles.
    setup_model

    setup_user(config)
    setup_message_history(config)
    @tools = build_tools
    @messages = build_messages(config)
  end

  def generate_response(input)
    @messages << { role: 'user', content: input } if input.present?
    response = request_chat_completion

    Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }
    Rails.logger.info(
      "#{self.class.name} Assistant: #{@assistant.id}, Incrementing response usage for account #{@account.id}"
    )
    @account.increment_response_usage

    response
  end

  private

  def setup_user(config)
    @user = @account.users.find_by(id: config[:user_id]) if config[:user_id].present?
  end

  def build_messages(config)
    messages= [system_message]
    messages << account_id_context
    messages += @previous_history if @previous_history.present?
    messages += current_viewing_history(config[:conversation_id]) if config[:conversation_id].present?
    messages
  end

  def setup_message_history(config)
    Rails.logger.info(
      "#{self.class.name} Assistant: #{@assistant.id}, Previous History: #{config[:previous_history]&.length || 0}, Language: #{config[:language]}"
    )

    @copilot_thread = @account.copilot_threads.find_by(id: config[:copilot_thread_id]) if config[:copilot_thread_id].present?
    @previous_history = if @copilot_thread.present?
                          @copilot_thread.previous_history
                        else
                          config[:previous_history].presence || []
                        end
  end

  def build_tools
    tools = []

    tools << Captain::Tools::SearchDocumentationService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::GetConversationService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::SearchConversationsService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::GetContactService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::GetArticleService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::SearchArticlesService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::SearchContactsService.new(@assistant, user: @user)
    tools << Captain::Tools::Copilot::SearchLinearIssuesService.new(@assistant, user: @user)

    tools.select(&:active?)
  end

  def system_message
    {
      role: 'system',
      content: Captain::Llm::SystemPromptsService.copilot_response_generator(
        @assistant.config['product_name'],
        tools_summary,
        @assistant.config
      )
    }
  end

  def tools_summary
    @tools.map { |tool| "- #{tool.class.name}: #{tool.class.description}" }.join("\n")
  end

  def account_id_context
    {
      role: 'system',
      content: "The current account id is #{@account.id}. The account is using #{@account.locale_english_name} as the language."
    }
  end

  def with_llm_credential
    Platform::CredentialManager.with_credential_context(
      account: @account,
      key: credential_key,
      provider: credential_provider,
      purpose: 'ai_provider'
    ) { |context, _credential| yield(context) }
  end

  def credential_key
    Platform::CredentialManager.default_key_for(credential_provider)
  end

  def credential_provider
    @resolved_credential&.provider ||
      Llm::Models.models[@model]&.fetch('provider', 'openai') ||
      'openai'
  end

  def resolver_account
    @account
  end

  def feature_key
    feature_name
  end

  def current_viewing_history(conversation_id)
    conversation = @account.conversations.find_by(display_id: conversation_id)
    return [] unless conversation

    Rails.logger.info("#{self.class.name} Assistant: #{@assistant.id}, Setting viewing history for conversation_id=#{conversation_id}")
    contact_id = conversation.contact_id
    [{
      role: 'system',
      content: <<~HISTORY.strip
        You are currently viewing the conversation with the following details:
        Conversation ID: #{conversation_id}
        Contact ID: #{contact_id}
      HISTORY
    }]
  end

  def persist_message(message, message_type = 'assistant')
    return if @copilot_thread.blank?

    @copilot_thread.copilot_messages.create!(
      message: message,
      message_type: message_type
    )
  end

  def feature_name
    'copilot'
  end
end
