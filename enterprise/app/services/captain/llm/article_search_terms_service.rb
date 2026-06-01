# Generates diverse search-term keywords/snippets for a help center article,
# used to build article embeddings. Provider-aware: routes to the account's
# configured chat model/credential (OpenAI or Gemini) via Llm::BaseAiService,
# replacing the previous raw OpenAI HTTP call (ENV['OPENAI_API_KEY'] + gpt-4o).
#
# No tools are used, so the JSON response mode is safe on Gemini too.
class Captain::Llm::ArticleSearchTermsService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  def initialize(article)
    @article = article
    # Set @article before super() so setup_model resolves the account's provider.
    super()
  end

  def generate
    response = instrument_llm_call(instrumentation_params) do
      chat
        .with_params(**json_mode_params)
        .with_instructions(system_prompt)
        .ask(user_content)
    end

    parse_terms(response.content)
  rescue StandardError => e
    Rails.logger.error "[Captain][ArticleSearchTerms] article=#{@article&.id}: #{e.class}: #{e.message}"
    []
  end

  private

  def resolver_account
    @article&.account
  end

  # Article search-term generation is a plain chat completion; resolve a chat
  # model rather than an embedding/transcription one.
  def resolver_kind
    'chat'
  end

  def parse_terms(content)
    parsed = JSON.parse(sanitize_json_response(content))
    Array(parsed['search_terms'])
  rescue JSON::ParserError, TypeError
    []
  end

  def user_content
    "title: #{@article.title} \n description: #{@article.description} \n content: #{@article.content}"
  end

  def system_prompt
    <<~SYSTEM_PROMPT_MESSAGE
      For the provided article content, generate potential search query keywords and snippets that can be used to generate the embeddings.
      Ensure the search terms are as diverse as possible but capture the essence of the article and are super related to the articles.
      Don't return any terms if there aren't any terms of relevance.
      Always return results in valid JSON of the following format
      {
        "search_terms": []
      }
    SYSTEM_PROMPT_MESSAGE
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.article_search_terms',
      model: @model,
      feature_name: 'article_search_terms',
      account_id: @article&.account_id,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: user_content }
      ]
    }
  end
end
