require 'rails_helper'

RSpec.describe Platform::Models::ResolutionCache do
  let(:account) { create(:account) }

  describe '.fetch' do
    it 'yields and caches on a miss, then returns the cached value without yielding again' do
      calls = 0
      compute = lambda do
        calls += 1
        { credential: nil, model_slug: 'gpt-5.1', source: :feature }
      end

      first = described_class.fetch(account.id, { feature: 'assistant' }, &compute)
      second = described_class.fetch(account.id, { feature: 'assistant' }, &compute)

      expect(first[:model_slug]).to eq('gpt-5.1')
      expect(second[:model_slug]).to eq('gpt-5.1')
      expect(calls).to eq(1)
    end

    it 'caches a nil result instead of recomputing it every time' do
      calls = 0
      compute = lambda do
        calls += 1
        nil
      end

      expect(described_class.fetch(account.id, { feature: 'assistant' }, &compute)).to be_nil
      expect(described_class.fetch(account.id, { feature: 'assistant' }, &compute)).to be_nil
      expect(calls).to eq(1)
    end

    it 'keys different cache_params separately' do
      expect(described_class.fetch(account.id, { feature: 'assistant' }) { { model_slug: 'a' } }[:model_slug]).to eq('a')
      expect(described_class.fetch(account.id, { feature: 'copilot' }) { { model_slug: 'b' } }[:model_slug]).to eq('b')
    end

    it 'falls back to yielding uncached when Redis read fails, instead of breaking the turn' do
      allow(Redis::Alfred).to receive(:get).and_raise(Redis::BaseError, 'down')

      result = described_class.fetch(account.id, { feature: 'assistant' }) { { model_slug: 'gpt-5.1' } }

      expect(result[:model_slug]).to eq('gpt-5.1')
    end
  end

  describe '.bump' do
    it 'invalidates a previously cached entry for that account' do
      described_class.fetch(account.id, { feature: 'assistant' }) { { model_slug: 'old' } }

      described_class.bump(account.id)

      result = described_class.fetch(account.id, { feature: 'assistant' }) { { model_slug: 'new' } }
      expect(result[:model_slug]).to eq('new')
    end

    it 'does nothing for a blank account_id' do
      expect { described_class.bump(nil) }.not_to raise_error
    end

    it 'never raises when Redis is unreachable' do
      allow(Redis::Alfred).to receive(:incr).and_raise(Redis::BaseError, 'down')

      expect { described_class.bump(account.id) }.not_to raise_error
    end
  end

  describe 'credential round-trip' do
    it 're-loads the cached credential by id rather than storing the AR object' do
      credential = create(:platform_credential, :openai, account: account)

      result = described_class.fetch(account.id, { feature: 'assistant' }) { { credential: credential, model_slug: 'gpt-5.1', source: :feature } }
      expect(result[:credential]).to eq(credential)

      cached = described_class.fetch(account.id, { feature: 'assistant' }) { raise 'should not recompute' }
      expect(cached[:credential]).to eq(credential)
      expect(cached[:source]).to eq(:feature)
    end

    it 'treats a cached entry whose credential id no longer resolves as a miss, not a stale reference' do
      key = described_class.entry_key(account.id, { feature: 'assistant' })
      Redis::Alfred.set(key, { credential_id: 999_999_999, model_slug: 'gpt-5.1', source: :feature }.to_json, ex: 60)

      recomputed = described_class.fetch(account.id, { feature: 'assistant' }) { { credential: nil, model_slug: 'fresh' } }

      expect(recomputed[:model_slug]).to eq('fresh')
    end

    it 'treats corrupt JSON in the cache as a miss' do
      key = described_class.entry_key(account.id, { feature: 'assistant' })
      Redis::Alfred.set(key, 'not json', ex: 60)

      recomputed = described_class.fetch(account.id, { feature: 'assistant' }) { { credential: nil, model_slug: 'fresh' } }

      expect(recomputed[:model_slug]).to eq('fresh')
    end
  end
end
