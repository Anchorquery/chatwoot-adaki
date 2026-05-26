class Campaigns::ApiWebhookDispatchPlannerService
  pattr_initialize [:message!, :inbox!]

  def perform
    campaign = message.conversation.campaign
    return Time.current unless campaign&.one_off?
    return Time.current unless campaign.inbox_id == inbox.id
    return Time.current if campaign.completed?

    campaign.with_lock do
      state = campaign.delivery_state.to_h.with_indifferent_access
      settings = campaign.delivery_settings.to_h.with_indifferent_access

      dispatch_at = current_dispatch_at(state)
      dispatch_at = align_to_business_hours(dispatch_at, campaign, settings)
      return nil if dispatch_at.nil?

      dispatch_at = align_to_rate_limit(dispatch_at, state, settings)
      return nil if dispatch_at.nil?

      scheduled_at = persist_schedule!(campaign, state, settings, dispatch_at)
      return nil if scheduled_at.nil?

      scheduled_at
    end
  end

  private

  def current_dispatch_at(state)
    next_dispatch_at = state[:webhook_next_dispatch_at].present? ? Time.at(state[:webhook_next_dispatch_at].to_i) : Time.current
    [next_dispatch_at, Time.current].max
  end

  def align_to_business_hours(dispatch_at, campaign, settings)
    business_hours_only = ActiveModel::Type::Boolean.new.cast(settings[:business_hours_only]) ||
                          ActiveModel::Type::Boolean.new.cast(campaign.trigger_only_during_business_hours)
    return dispatch_at unless business_hours_only

    next_open_time_for(campaign.inbox, dispatch_at)
  end

  def align_to_rate_limit(dispatch_at, state, settings)
    max_per_minute = settings[:max_messages_per_minute].to_i
    return dispatch_at unless max_per_minute.positive?

    window_started_at = state[:webhook_window_started_at].present? ? Time.at(state[:webhook_window_started_at].to_i) : dispatch_at
    window_sent_count = state[:webhook_window_sent_count].to_i

    if dispatch_at - window_started_at >= 60.seconds
      window_started_at = dispatch_at
      window_sent_count = 0
    end

    if window_sent_count >= max_per_minute
      window_started_at = window_started_at + 60.seconds
      window_sent_count = 0
      dispatch_at = window_started_at
    end

    state[:webhook_window_started_at] = window_started_at.to_i
    state[:webhook_window_sent_count] = window_sent_count
    dispatch_at
  end

  def persist_schedule!(campaign, state, settings, dispatch_at)
    delay_between_messages = settings[:delay_between_messages_seconds].to_i
    delay_between_batches = settings[:delay_between_batches_seconds].to_i
    batch_size = settings[:batch_size].to_i
    max_daily_messages = settings[:max_daily_messages].to_i

    sent_on = state[:webhook_last_sent_on].to_s
    today = dispatch_at.to_date.to_s
    daily_sent_count = sent_on == today ? state[:webhook_daily_sent_count].to_i : 0

    if max_daily_messages.positive? && daily_sent_count >= max_daily_messages
      campaign.paused!
      state[:errors] = Array(state[:errors])
      state[:errors] << { system: 'Daily delivery limit reached', time: Time.current }
      campaign.update!(delivery_state: state)
      return nil
    end

    batch_sent_count = state[:webhook_batch_sent_count].to_i + 1
    next_gap = if batch_size.positive? && batch_sent_count >= batch_size
                 state[:webhook_batch_sent_count] = 0
                 delay_between_batches.seconds
               else
                 state[:webhook_batch_sent_count] = batch_sent_count
                 delay_between_messages.seconds
               end

    state[:webhook_daily_sent_count] = daily_sent_count + 1
    state[:webhook_last_sent_on] = today
    state[:webhook_window_sent_count] = state[:webhook_window_sent_count].to_i + 1
    state[:webhook_next_dispatch_at] = (dispatch_at + next_gap).to_i
    campaign.update!(delivery_state: state)
    dispatch_at
  end

  def next_open_time_for(inbox, from_time)
    time_zone = ActiveSupport::TimeZone[inbox.timezone] || Time.zone
    local_time = from_time.in_time_zone(time_zone)

    0.upto(7) do |offset|
      date = local_time.to_date + offset.days
      working_hour = inbox.working_hours.find_by(day_of_week: date.wday)
      next if working_hour.blank? || working_hour.closed_all_day?

      open_time = time_zone.local(date.year, date.month, date.day, working_hour.open_hour, working_hour.open_minutes, 0)
      close_time = time_zone.local(date.year, date.month, date.day, working_hour.close_hour, working_hour.close_minutes, 0)

      return from_time if local_time.between?(open_time, close_time)
      return open_time.utc if local_time < open_time
    end

    from_time
  end
end
