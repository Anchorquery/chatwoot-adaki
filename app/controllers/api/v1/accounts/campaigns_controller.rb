class Api::V1::Accounts::CampaignsController < Api::V1::Accounts::BaseController
  before_action :campaign, except: [:index, :create, :ai_generate, :clone, :results, :retry_failed]
  before_action :campaign_for_results, only: [:results, :retry_failed]
  before_action :find_campaign_for_clone, only: [:clone]
  before_action :check_authorization
  before_action :check_clone_authorization, only: [:clone]
  before_action :parse_delivery_settings, only: [:create, :update]
  after_action :trigger_immediate_dispatch, only: [:create, :update]

  def index
    scope = Current.account.campaigns

    if params[:channel_types].present?
      channel_types = Array(params[:channel_types])
      scope = scope.joins(:inbox).where(inboxes: { channel_type: channel_types })
    end

    scope = scope.where(campaign_status: params[:status]) if params[:status].present?

    if params[:q].present?
      q = "%#{params[:q].strip.downcase}%"
      scope = scope.where('LOWER(campaigns.title) LIKE :q', q: q)
    end

    @total_count = scope.count
    @current_page = [params[:page].to_i, 1].max
    per_page = 15
    @campaigns = scope.order(created_at: :desc).page(@current_page).per(per_page)
    @per_page = per_page
  end

  def show; end

  def create
    @campaign = Current.account.campaigns.new(campaign_params.except(:attachments))
    attach_files_to(@campaign)
    @campaign.save!
  end

  def update
    @campaign.update!(campaign_params.except(:attachments))
    @campaign.update!(campaign_status: :active) if @campaign.draft?
    remove_files_from(@campaign)
    attach_files_to(@campaign)
  end

  def destroy
    @campaign.destroy!
    head :ok
  end

  def clone
    @campaign = @source_campaign.dup
    @campaign.display_id = nil
    @campaign.title = "#{@source_campaign.title} (copia)"
    @campaign.campaign_status = :active
    @campaign.scheduled_at = 1.day.from_now
    @campaign.delivery_state = nil
    @campaign.requires_approval = false if @campaign.respond_to?(:requires_approval=)
    @campaign.save!
    render :show
  end

  def results
    state = @campaign.delivery_state.to_h.with_indifferent_access
    recipients_map = state[:recipients].to_h
    contact_ids = (state[:contact_ids] || []).map(&:to_i)

    status_filter = params[:status].to_s.presence
    query = params[:q].to_s.strip.downcase

    filtered_ids = case status_filter
                   when 'sent'
                     recipients_map.select { |_, v| v['status'] == 'sent' }.keys.map(&:to_i)
                   when 'failed'
                     recipients_map.select { |_, v| v['status'] == 'failed' }.keys.map(&:to_i)
                   when 'skipped'
                     recipients_map.select { |_, v| v['status'] == 'skipped' }.keys.map(&:to_i)
                   else
                     contact_ids
                   end

    contacts_scope = Current.account.contacts.where(id: filtered_ids)
    if query.present?
      contacts_scope = contacts_scope.where(
        'LOWER(name) LIKE :q OR phone_number LIKE :q OR email LIKE :q',
        q: "%#{query}%"
      )
    end

    per_page = 25
    page = [params[:page].to_i, 1].max
    total = contacts_scope.count
    contacts = contacts_scope.order(:name).offset((page - 1) * per_page).limit(per_page)

    sent_count = state[:sent_count].to_i
    failed_count = state[:failed_count].to_i
    total_contacts = state[:total_contacts].to_i
    started_at = state[:started_at]
    completed_at = state[:completed_at]

    duration_seconds = if started_at && completed_at
                         (Time.parse(completed_at) - Time.parse(started_at)).round
                       end
    throughput = if duration_seconds&.positive? && sent_count.positive?
                   (sent_count.to_f / (duration_seconds / 60.0)).round(1)
                 end
    success_rate = total_contacts.positive? ? (sent_count.to_f / total_contacts * 100).round(1) : nil

    render json: {
      contacts: contacts.map do |c|
        info = recipients_map[c.id.to_s] || {}
        {
          id: c.id,
          name: c.name,
          phone_number: c.phone_number,
          email: c.email,
          avatar_url: c.avatar_url,
          status: info['status'] || 'pending',
          sent_at: info['sent_at'],
          failed_at: info['failed_at'],
          skipped_at: info['skipped_at'],
          error: info['error'],
          conversation_id: info['conversation_id']
        }
      end,
      meta: {
        total: total,
        page: page,
        per_page: per_page,
        total_pages: [(total.to_f / per_page).ceil, 1].max
      },
      stats: {
        total_contacts: total_contacts,
        sent_count: sent_count,
        failed_count: failed_count,
        processed_index: state[:processed_index].to_i,
        started_at: started_at,
        completed_at: completed_at,
        duration_seconds: duration_seconds,
        throughput_per_minute: throughput,
        success_rate: success_rate
      }
    }
  end

  def retry_failed
    state = @campaign.delivery_state.to_h.with_indifferent_access
    recipients_map = state[:recipients].to_h

    failed_ids = recipients_map.select { |_, v| v['status'] == 'failed' }.keys.map(&:to_i)
    return render json: { error: 'No failed contacts to retry' }, status: :unprocessable_entity if failed_ids.empty?

    # Remove failed entries so they get re-attempted
    failed_ids.each { |id| recipients_map.delete(id.to_s) }

    already_done_ids = recipients_map.select { |_, v| %w[sent skipped].include?(v['status']) }.keys.map(&:to_i)
    all_original_ids = (state[:contact_ids] || []).map(&:to_i)
    processed_ids = recipients_map.keys.map(&:to_i)
    unprocessed_ids = all_original_ids - processed_ids - already_done_ids

    # Order: already done (skip by index) → failed (retry) → never processed
    new_contact_ids = already_done_ids + failed_ids + unprocessed_ids

    @campaign.update!(
      campaign_status: :running,
      delivery_state: state.merge(
        contact_ids: new_contact_ids,
        total_contacts: new_contact_ids.size,
        processed_index: already_done_ids.size,
        failed_count: 0,
        consecutive_failures: 0,
        recipients: recipients_map
      )
    )

    Campaigns::ProcessBatchJob.perform_later(@campaign)
    render json: { message: 'Retry enqueued', retry_count: failed_ids.size + unprocessed_ids.size }
  end

  def ai_generate
    if params[:prompt].to_s.strip.blank?
      render json: { error: 'Prompt is required.' }, status: :bad_request
      return
    end

    allowed_styles = %w[concise standard detailed]
    allowed_context_sources = %w[none guidelines documents]
    style = allowed_styles.include?(params[:style]) ? params[:style] : 'standard'
    context_source = allowed_context_sources.include?(params[:context_source]) ? params[:context_source] : 'none'
    use_emojis = ActiveModel::Type::Boolean.new.cast(params[:use_emojis])
    assistant = Current.account.captain_assistants.find_by(id: params[:assistant_id])

    result = Captain::Llm::CampaignCopyService.new(
      account: Current.account,
      prompt: params[:prompt].to_s,
      tone: params[:tone].presence || 'friendly',
      goal: params[:goal].presence || 'informative',
      assistant: assistant,
      use_emojis: use_emojis,
      style: style,
      context_source: context_source
    ).perform

    if result[:error]
      render json: { error: result[:error] }, status: (result[:error_code] || :unprocessable_entity)
      return
    end

    render json: result[:message]
  rescue CustomExceptions::Platform::MissingCredential
    render json: { error: 'OpenAI credential not configured.' }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error("[CampaignCopy] #{e.class}: #{e.message}")
    render json: { error: "Failed to generate campaign copy: #{e.message}" }, status: :bad_request
  end

  private

  def check_clone_authorization
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end

  def campaign
    @campaign ||= Current.account.campaigns.find_by(display_id: params[:id])
  end

  def trigger_immediate_dispatch
    return unless @campaign&.persisted?
    return unless @campaign.campaign_type == 'one_off'
    return unless @campaign.campaign_status == 'active'
    return unless @campaign.delivery_settings&.dig('immediate_dispatch')
    return unless @campaign.scheduled_at.present? && @campaign.scheduled_at <= Time.current

    Campaigns::TriggerOneoffCampaignJob.perform_later(@campaign)
  end

  def campaign_for_results
    @campaign = Current.account.campaigns.find_by(display_id: params[:id])
    head :not_found unless @campaign
  end

  def find_campaign_for_clone
    @source_campaign = Current.account.campaigns.find_by(display_id: params[:id])
    head :not_found unless @source_campaign
  end

  def attach_files_to(campaign)
    files = params.dig(:campaign, :attachments)
    return if files.blank?

    Array(files).each do |file|
      campaign.attachments.attach(file)
    end
  end

  def remove_files_from(campaign)
    attachment_ids = Array(params.dig(:campaign, :attachment_ids_to_remove)).reject(&:blank?)
    return if attachment_ids.blank?

    campaign.attachments_attachments.where(id: attachment_ids).each(&:purge)
  end

  def parse_delivery_settings
    raw = params.dig(:campaign, :delivery_settings)
    return unless raw.is_a?(String)

    params[:campaign][:delivery_settings] = JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def campaign_params
    params.require(:campaign).permit(
      :title, :description, :message, :enabled, :trigger_only_during_business_hours,
      :inbox_id, :sender_id, :scheduled_at, :requires_approval,
      audience: [:type, :id],
      trigger_rules: {},
      template_params: {},
      delivery_settings: {},
      attachment_ids_to_remove: [],
      attachments: []
    )
  end

end
