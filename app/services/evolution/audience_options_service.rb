class Evolution::AudienceOptionsService
  def initialize(inbox)
    @inbox = inbox
    @config = inbox.channel.try(:additional_attributes) || {}
  end

  def newsletters
    fetch('newsletter/find')
  end

  def groups
    fetch('group/fetchAllGroups', getParticipants: 'false')
  end

  private

  def fetch(path, query = {})
    return [] unless configured?

    response = HTTParty.get(
      "#{base_url}/#{path}/#{instance_name}",
      headers: { 'apikey' => api_key },
      query: query,
      timeout: 10
    )
    return [] unless response.success?

    Array.wrap(response.parsed_response)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    []
  end

  def configured?
    base_url.present? && api_key.present? && instance_name.present?
  end

  def base_url
    @config['evolution_base_url']
  end

  def api_key
    @config['evolution_api_key']
  end

  def instance_name
    @config['evolution_instance_name']
  end
end
