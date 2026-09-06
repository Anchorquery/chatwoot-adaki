require 'rails_helper'

RSpec.describe Captain::Llm::EmbeddingService do
  let(:account) { create(:account) }
  let(:vectors) { Array.new(4) { rand } }
  let(:query) { "¿Cuánto cuesta el pack de 3? #{SecureRandom.hex(4)}" }

  before do
    allow(RubyLLM).to receive(:embed).and_return(instance_double(RubyLLM::Embedding, vectors: vectors))
  end

  it 'embeds a search query once and serves repeats (same text modulo case/spacing) from Redis' do
    service = described_class.new(account: account, purpose: :search)

    expect(service.get_embedding(query)).to eq(vectors)
    expect(service.get_embedding("  #{query.upcase}  ")).to eq(vectors)
    expect(described_class.new(account: account, purpose: :search).get_embedding(query)).to eq(vectors)

    expect(RubyLLM).to have_received(:embed).once
  end

  it 'does not cache write-side embeddings (FAQ content)' do
    service = described_class.new(account: account, purpose: :write)

    service.get_embedding(query)
    service.get_embedding(query)

    expect(RubyLLM).to have_received(:embed).twice
  end

  it 'keys the cache by model so a provider switch never serves vectors from another space' do
    service = described_class.new(account: account, purpose: :search)

    service.get_embedding(query, model: 'text-embedding-3-small')
    service.get_embedding(query, model: 'gemini-embedding-001')

    expect(RubyLLM).to have_received(:embed).twice
  end

  it 'falls back to the provider when Redis is unavailable' do
    allow(Redis::Alfred).to receive(:get).and_raise(Redis::CannotConnectError, 'down')
    allow(Redis::Alfred).to receive(:setex).and_raise(Redis::CannotConnectError, 'down')
    service = described_class.new(account: account, purpose: :search)

    expect(service.get_embedding(query)).to eq(vectors)
    expect(RubyLLM).to have_received(:embed).once
  end
end
