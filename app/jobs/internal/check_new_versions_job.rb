class Internal::CheckNewVersionsJob < ApplicationJob
  queue_as :scheduled_jobs

  # Adaki is a disconnected fork — it no longer phones home to the upstream
  # Chatwoot hub (hub.2.chatwoot.com) to check for new versions or sync plan info.
  def perform
    @instance_info = nil
  end

  private

  def update_version_info
    return if @instance_info.blank? || @instance_info['version'].blank?

    ::Redis::Alfred.set(::Redis::Alfred::LATEST_CHATWOOT_VERSION, @instance_info['version'])
  end
end

Internal::CheckNewVersionsJob.prepend_mod_with('Internal::CheckNewVersionsJob')
