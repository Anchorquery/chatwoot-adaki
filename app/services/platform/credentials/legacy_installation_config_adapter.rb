module Platform::Credentials
  class LegacyInstallationConfigAdapter
    def self.fetch(key)
      payload = {}
      metadata = {}

      case key.to_s
      when 'openai.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
        metadata[:api_base] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
        metadata[:model] = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value
      when 'anthropic.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_ANTHROPIC_API_KEY')&.value
      when 'gemini.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_GEMINI_API_KEY')&.value
      when 'deepseek.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_DEEPSEEK_API_KEY')&.value
      when 'openrouter.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.value
      when 'ollama.default'
        metadata[:api_base] = InstallationConfig.find_by(name: 'CAPTAIN_OLLAMA_API_BASE')&.value
      when 'bedrock.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_API_KEY')&.value
        payload[:secret_key] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_SECRET_KEY')&.value
        metadata[:region] = InstallationConfig.find_by(name: 'CAPTAIN_BEDROCK_REGION')&.value
      when 'firecrawl.default'
        payload[:api_key] = InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value
      else
        return nil
      end

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
