require 'rails_helper'

RSpec.describe Captain::FailurePolicy do
  # Faraday::Response-shaped enough for FailurePolicy#error_response_body,
  # without depending on Faraday::Response's exact real interface.
  def error_with_body(klass, body_text)
    klass.new(Struct.new(:body).new(body_text))
  end

  describe '.classify' do
    it 'classifies Adaki::CaptainUsageTracker::LimitExceeded as limit_adaki' do
      expect(described_class.classify(Adaki::CaptainUsageTracker::LimitExceeded.new)).to eq(:limit_adaki)
    end

    it 'classifies RubyLLM::ContextLengthExceededError as budget' do
      expect(described_class.classify(RubyLLM::ContextLengthExceededError.new('prompt too long'))).to eq(:budget)
    end

    it 'classifies RubyLLM::ConfigurationError as configuration' do
      expect(described_class.classify(RubyLLM::ConfigurationError.new('missing api key'))).to eq(:configuration)
    end

    it 'classifies RubyLLM::UnauthorizedError as configuration (OpenAI: dead/revoked key, HTTP 401)' do
      expect(described_class.classify(RubyLLM::UnauthorizedError.new('Incorrect API key provided'))).to eq(:configuration)
    end

    it 'classifies RubyLLM::PaymentRequiredError as configuration' do
      expect(described_class.classify(RubyLLM::PaymentRequiredError.new('payment required'))).to eq(:configuration)
    end

    it 'classifies RubyLLM::ForbiddenError as configuration' do
      expect(described_class.classify(RubyLLM::ForbiddenError.new('forbidden'))).to eq(:configuration)
    end

    it 'classifies RubyLLM::RateLimitError as transient by default (plain rate limiting)' do
      expect(described_class.classify(RubyLLM::RateLimitError.new('slow down'))).to eq(:transient)
    end

    it 'classifies RubyLLM::ServerError as transient' do
      expect(described_class.classify(RubyLLM::ServerError.new('internal error'))).to eq(:transient)
    end

    it 'classifies RubyLLM::ServiceUnavailableError as transient' do
      expect(described_class.classify(RubyLLM::ServiceUnavailableError.new('unavailable'))).to eq(:transient)
    end

    it 'classifies RubyLLM::OverloadedError as transient' do
      expect(described_class.classify(RubyLLM::OverloadedError.new('overloaded'))).to eq(:transient)
    end

    it 'classifies Faraday::TimeoutError as transient' do
      expect(described_class.classify(Faraday::TimeoutError.new('timed out'))).to eq(:transient)
    end

    it 'classifies Faraday::ConnectionFailed as transient' do
      expect(described_class.classify(Faraday::ConnectionFailed.new('connection refused'))).to eq(:transient)
    end

    it 'classifies Timeout::Error as transient' do
      expect(described_class.classify(Timeout::Error.new)).to eq(:transient)
    end

    it "classifies its own TransientProviderError wrapper as transient (doesn't need re-wrapping)" do
      expect(described_class.classify(described_class::TransientProviderError.new('already classified'))).to eq(:transient)
    end

    it 'classifies an unrecognized error as unknown, not silently as any of the above' do
      expect(described_class.classify(StandardError.new('mystery failure'))).to eq(:unknown)
    end

    context 'when Gemini reports an invalid API key as HTTP 400 (BadRequestError), not 401' do
      it 'classifies it as configuration when the body carries the API_KEY_INVALID marker' do
        error = error_with_body(
          RubyLLM::BadRequestError,
          '{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT","reason":"API_KEY_INVALID"}}'
        )

        expect(described_class.classify(error)).to eq(:configuration)
      end

      it 'classifies a plain BadRequestError (no API_KEY_INVALID marker) as unknown, not configuration' do
        error = error_with_body(RubyLLM::BadRequestError, '{"error":{"message":"malformed request body"}}')

        expect(described_class.classify(error)).to eq(:unknown)
      end

      it 'does not blow up on a BadRequestError with no response at all' do
        expect(described_class.classify(RubyLLM::BadRequestError.new('bad request'))).to eq(:unknown)
      end
    end

    context 'when OpenAI reports exhausted billing quota as HTTP 429 (RateLimitError), same status as plain rate limiting' do
      it 'classifies it as configuration (permanent) when the body carries insufficient_quota' do
        error = error_with_body(
          RubyLLM::RateLimitError,
          '{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}'
        )

        expect(described_class.classify(error)).to eq(:configuration)
      end

      it 'classifies a plain rate-limit 429 (no insufficient_quota marker) as transient' do
        error = error_with_body(
          RubyLLM::RateLimitError,
          '{"error":{"message":"Rate limit reached for requests","code":"rate_limit_exceeded"}}'
        )

        expect(described_class.classify(error)).to eq(:transient)
      end
    end
  end

  describe '.transient?' do
    it 'is true only when classify returns :transient' do
      expect(described_class.transient?(RubyLLM::ServerError.new('x'))).to be(true)
      expect(described_class.transient?(RubyLLM::UnauthorizedError.new('x'))).to be(false)
    end
  end

  describe '.configuration?' do
    it 'is true only when classify returns :configuration' do
      expect(described_class.configuration?(RubyLLM::UnauthorizedError.new('x'))).to be(true)
      expect(described_class.configuration?(RubyLLM::ServerError.new('x'))).to be(false)
    end
  end

  describe '.budget?' do
    it 'is true only when classify returns :budget' do
      expect(described_class.budget?(RubyLLM::ContextLengthExceededError.new('x'))).to be(true)
      expect(described_class.budget?(RubyLLM::ServerError.new('x'))).to be(false)
    end
  end

  describe '.limit_adaki?' do
    it 'is true only when classify returns :limit_adaki' do
      expect(described_class.limit_adaki?(Adaki::CaptainUsageTracker::LimitExceeded.new)).to be(true)
      expect(described_class.limit_adaki?(RubyLLM::ServerError.new('x'))).to be(false)
    end
  end
end
