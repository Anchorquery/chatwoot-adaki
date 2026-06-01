# Resolves a model for a specific *capability* (one or more CredentialModel
# kinds) for an account, building the per-credential RubyLLM context in one go.
#
# Unlike Platform::Models::Resolver (which is chat-oriented and falls back to any
# enabled model / the account's first credential), this resolver is STRICT about
# kind: it only returns a model whose kind is in the requested list, so an audio
# transcription request never accidentally resolves to a chat/embedding model.
# Returns nil when no matching enabled model exists, letting callers fall back to
# their provider default (e.g. OpenAI whisper-1 / text-embedding-3-small).
#
# When several kinds are passed they act as an ordered preference
# (e.g. %w[transcription multimodal] prefers a dedicated transcription model,
# then a multimodal one that can also transcribe — as Gemini does).
module Platform::Models
  class CapabilityResolver
    Result = Struct.new(:credential, :model_slug, :provider, :context, keyword_init: true)

    def self.resolve(account:, kinds:)
      new(account: account, kinds: kinds).resolve
    end

    def initialize(account:, kinds:)
      @account = account
      @kinds = Array(kinds).map(&:to_s)
    end

    def resolve
      return nil if @account.nil? || @kinds.empty?

      model = best_model
      return nil unless model

      credential = model.credential
      Result.new(
        credential: credential,
        model_slug: model.slug,
        provider: credential.provider.to_s,
        context: Llm::Config.context_for_credential(credential)
      )
    end

    private

    def best_model
      candidates = Platform::CredentialModel.enabled
                                            .where(kind: @kinds)
                                            .joins(:credential)
                                            .where(platform_credentials: { account_id: @account.id })
                                            .merge(Platform::Credential.active)
                                            .to_a
      return nil if candidates.empty?

      # Honor the kinds order as a preference, then deterministic by id.
      candidates.min_by { |m| [@kinds.index(m.kind) || @kinds.size, m.id] }
    end
  end
end
