class Enterprise::Webhooks::FirecrawlController < ActionController::API
  before_action :validate_token

  def process_payload
    if crawl_page_event?
      Captain::Tools::FirecrawlParserJob.perform_later(
        assistant_id: assistant.id,
        payload: payload,
        root_url: permitted_params[:root_url],
        crawl_mode: 'website',
        crawl_depth: permitted_params[:crawl_depth]
      )
    end

    head :ok
  end

  private

  include Captain::FirecrawlHelper

  def payload
    permitted_params[:data]&.first&.to_h
  end

  def validate_token
    render json: { error: 'Invalid access_token' }, status: :unauthorized if assistant_token != permitted_params[:token]
  end

  def assistant
    @assistant ||= Captain::Assistant.find(permitted_params[:assistant_id])
  end

  def assistant_token
    generate_firecrawl_token(assistant.id, assistant.account_id)
  end

  def crawl_page_event?
    permitted_params[:type] == 'crawl.page'
  end

  def permitted_params
    params.permit(
      :type,
      :assistant_id,
      :token,
      :success,
      :id,
      :metadata,
      :root_url,
      :crawl_depth,
      :format,
      :firecrawl,
      data: [:markdown, { metadata: {} }]
    )
  end
end
