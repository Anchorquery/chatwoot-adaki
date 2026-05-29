module Platform::Models
  class Importer
    class SyncError < StandardError; end

    # Providers handled via OpenAI-compatible /v1/models endpoint
    OPENAI_COMPATIBLE_DEFAULTS = {
      'openai'     => 'https://api.openai.com/v1',
      'deepseek'   => 'https://api.deepseek.com/v1',
      'openrouter' => 'https://openrouter.ai/api/v1',
      'mistral'    => 'https://api.mistral.ai/v1',
      'groq'       => 'https://api.groq.com/openai/v1'
    }.freeze

    def initialize(credential)
      @credential = credential
    end

    def sync_remote!
      entries = fetch_remote
      now = Time.current

      entries.map { |attrs| upsert(attrs.merge(synced_at: now)) }.compact
    end

    private

    def fetch_remote
      provider = @credential.provider

      return fetch_openai_compatible(OPENAI_COMPATIBLE_DEFAULTS[provider]) if OPENAI_COMPATIBLE_DEFAULTS.key?(provider)

      case provider
      when 'anthropic'    then fetch_anthropic
      when 'gemini'       then fetch_gemini
      when 'ollama'       then fetch_ollama
      when 'azure_openai' then fetch_azure_openai
      when 'custom'       then fetch_openai_compatible(nil)
      when 'perplexity'
        raise SyncError, 'Perplexity does not expose a public models listing endpoint. Add models manually.'
      when 'tavily'
        raise SyncError, 'Tavily is a search API, not an LLM provider. Configure search settings manually.'
      when 'bedrock'
        raise SyncError, 'Bedrock requires AWS SDK + IAM credentials. Configure models manually.'
      when 'firecrawl'
        raise SyncError, 'Firecrawl is a scraping service. No model listing available.'
      else
        raise SyncError, "Provider '#{provider}' does not support remote model listing. Add models manually."
      end
    end

    def fetch_openai_compatible(default_base)
      api_key = @credential.secret(:api_key)
      raise SyncError, 'Missing api_key' if api_key.blank?

      base = api_base(default_base)
      raise SyncError, 'Missing api_base URL for custom provider' if base.blank?

      url = "#{base.chomp('/')}/models"
      response = HTTParty.get(url, headers: { 'Authorization' => "Bearer #{api_key}" }, timeout: 15)
      raise SyncError, error_message(response) unless response.success?

      Array(response.parsed_response['data']).filter_map do |entry|
        slug = entry['id']
        next if slug.blank?

        attrs = {
          slug: slug,
          display_name: (entry['name'].presence || slug),
          kind: classify_kind(slug),
          description: entry['description'],
          context_window: entry['context_length'],
          capabilities: [],
          raw_metadata: entry
        }

        pricing = entry['pricing']
        if pricing.is_a?(Hash)
          attrs[:input_price_per_million]  = price_per_million(pricing['prompt'])
          attrs[:output_price_per_million] = price_per_million(pricing['completion'])
        end

        modalities = Array(entry.dig('architecture', 'input_modalities'))
        attrs[:kind] = 'multimodal' if modalities.include?('image')

        attrs
      end
    end

    def fetch_anthropic
      api_key = @credential.secret(:api_key)
      raise SyncError, 'Missing api_key' if api_key.blank?

      url = "#{api_base('https://api.anthropic.com').chomp('/')}/v1/models"
      response = HTTParty.get(
        url,
        headers: { 'x-api-key' => api_key, 'anthropic-version' => '2023-06-01' },
        timeout: 15
      )
      raise SyncError, error_message(response) unless response.success?

      Array(response.parsed_response['data']).filter_map do |entry|
        slug = entry['id']
        next if slug.blank?

        {
          slug: slug,
          display_name: entry['display_name'].presence || slug,
          kind: classify_kind(slug),
          capabilities: %w[vision tools json],
          raw_metadata: entry
        }
      end
    end

    def fetch_gemini
      api_key = @credential.secret(:api_key)
      raise SyncError, 'Missing api_key' if api_key.blank?

      url = "#{api_base('https://generativelanguage.googleapis.com').chomp('/')}/v1beta/models?key=#{api_key}"
      response = HTTParty.get(url, timeout: 15)
      raise SyncError, error_message(response) unless response.success?

      Array(response.parsed_response['models']).filter_map do |entry|
        full_name = entry['name'].to_s
        slug = full_name.sub(%r{\Amodels/}, '')
        next if slug.blank?

        methods = Array(entry['supportedGenerationMethods'])
        kind = if methods.include?('embedContent')
                 'embedding'
               elsif slug.include?('image') || slug.include?('imagen')
                 'image'
               else
                 classify_kind(slug)
               end

        {
          slug: slug,
          display_name: entry['displayName'].presence || slug,
          kind: kind,
          description: entry['description'],
          context_window: entry['inputTokenLimit'],
          max_output_tokens: entry['outputTokenLimit'],
          capabilities: [],
          raw_metadata: entry
        }
      end
    end

    def fetch_ollama
      base = api_base('http://localhost:11434').chomp('/').sub(%r{/v1\z}, '')
      url = "#{base}/api/tags"
      response = HTTParty.get(url, timeout: 15)
      raise SyncError, error_message(response) unless response.success?

      Array(response.parsed_response['models']).filter_map do |entry|
        raw_name = (entry['name'] || entry['model']).to_s
        slug = raw_name.split(':').first
        next if slug.blank?

        details = entry['details'] || {}
        description = ['Family: ' + details['family'].to_s, 'Size: ' + details['parameter_size'].to_s, details['quantization_level'].to_s]
                      .reject { |s| s.end_with?(': ') || s.empty? }.join(' · ')

        {
          slug: slug,
          display_name: raw_name,
          kind: classify_kind(slug),
          description: description.presence,
          capabilities: [],
          raw_metadata: entry
        }
      end
    end

    def fetch_azure_openai
      api_key = @credential.secret(:api_key)
      raise SyncError, 'Missing api_key' if api_key.blank?

      base = api_base(nil)
      raise SyncError, 'Azure OpenAI requires api_base URL like https://{resource}.openai.azure.com' if base.blank?

      api_version = @credential.metadata['api_version'].presence || '2024-02-15-preview'
      url = "#{base.chomp('/')}/openai/deployments?api-version=#{api_version}"

      response = HTTParty.get(url, headers: { 'api-key' => api_key }, timeout: 15)
      raise SyncError, error_message(response) unless response.success?

      Array(response.parsed_response['data']).filter_map do |entry|
        slug = entry['id'] || entry['deployment_id']
        next if slug.blank?

        underlying = entry.dig('model') || slug
        {
          slug: slug,
          display_name: "#{slug} (#{underlying})",
          kind: classify_kind(underlying.to_s),
          capabilities: [],
          raw_metadata: entry
        }
      end
    end

    def upsert(attrs)
      model = @credential.models.find_or_initialize_by(slug: attrs[:slug])
      preserved_enabled = model.persisted? ? model.enabled : false
      persisted = model.persisted?

      attrs.except(:enabled).each do |k, v|
        next unless model.respond_to?("#{k}=")
        # Preserve manual edits: if API returned blank/nil and the record
        # already has a value, keep it. New records take the incoming value
        # even if blank so defaults can be applied.
        next if persisted && v.blank?

        model.send("#{k}=", v)
      end
      model.enabled = preserved_enabled
      model.save!
      model
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Platform::Models::Importer] skip #{attrs[:slug]}: #{e.message}")
      nil
    end

    def api_base(default_base)
      @credential.metadata['api_base'].presence || default_base
    end

    def error_message(response)
      "Provider responded #{response.code}: #{response.body.to_s[0, 200]}"
    end

    def price_per_million(value)
      return nil if value.nil?

      n = value.to_f
      return nil if n.zero?

      (n * 1_000_000).round(4)
    end

    def classify_kind(slug)
      s = slug.downcase
      return 'embedding' if s.include?('embed')
      return 'transcription' if s.include?('whisper') || s.include?('transcribe')
      return 'tts' if s.include?('tts') || s.include?('speech')
      return 'image' if s.include?('dall-e') || s.include?('imagen') || s.include?('flux') || s.include?('stable-diffusion')
      return 'video' if s.include?('sora') || s.include?('veo')
      return 'realtime' if s.include?('realtime')
      return 'multimodal' if s.match?(/-4o(\b|-)/) || s.include?('gemini') || s.include?('claude') || s.include?('vision') || s.include?('llava')
      'chat'
    end
  end
end
