module Platform::Credentials
  class LegacyInstallationConfigAdapter
    def self.fetch(key)
      payload = {}
      metadata = {}

      case key.to_s
      when 'openai.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value.presence
        metadata[:api_base] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value.presence
        metadata[:model] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence
      when 'anthropic.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_ANTHROPIC_API_KEY')&.value.presence
      when 'gemini.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_GEMINI_API_KEY')&.value.presence
      when 'deepseek.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_DEEPSEEK_API_KEY')&.value.presence
      when 'openrouter.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.value.presence
      when 'ollama.default'
        metadata[:api_base] = InstallationConfig.find_by(name: 'CAPTAIN_OLLAMA_API_BASE')&.value.presence
      when 'bedrock.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_API_KEY')&.value.presence
        payload[:secret_key] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_SECRET_KEY')&.value.presence
        metadata[:region] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_REGION')&.value.presence
      when 'firecrawl.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value.presence
      else
        return nil
      end

      payload.compact!
      metadata.compact!

      return nil if payload.blank? && metadata.blank?

      {
        provider: key.to_s.split('.').first,
        purpose: 'legacy',
        key: key.to_s,
        name: key.to_s.humanize,
        auth_type: 'api_key',
        payload: payload,
        metadata: metadata
      }
    end
  end
end
