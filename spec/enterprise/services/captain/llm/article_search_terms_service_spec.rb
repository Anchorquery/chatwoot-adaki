require 'rails_helper'

RSpec.describe Captain::Llm::ArticleSearchTermsService do
  let(:account) { create(:account) }
  let(:article) { create(:article, account: account, title: 'Refunds', content: 'How to request a refund') }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'global-key')
    Llm::Config.reset!
  end

  def stub_chat_returning(content)
    chat = double('chat')
    allow(chat).to receive(:with_params).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    response = double('response', content: content)
    allow(chat).to receive(:ask).and_return(response)
    chat
  end

  it 'parses the search_terms array from a JSON response' do
    service = described_class.new(article)
    allow(service).to receive(:chat).and_return(stub_chat_returning('{"search_terms": ["refund", "money back"]}'))

    expect(service.generate).to eq(%w[refund money\ back])
  end

  it 'tolerates fenced JSON' do
    service = described_class.new(article)
    allow(service).to receive(:chat).and_return(stub_chat_returning("```json\n{\"search_terms\": [\"a\"]}\n```"))

    expect(service.generate).to eq(['a'])
  end

  it 'returns [] on invalid JSON instead of raising' do
    service = described_class.new(article)
    allow(service).to receive(:chat).and_return(stub_chat_returning('not json'))

    expect(service.generate).to eq([])
  end

  it 'resolves a chat model for the article account (provider-aware)' do
    credential = create(:platform_credential, :gemini, account: account)
    create(:platform_credential_model, credential: credential, slug: 'gemini-3-flash', kind: 'chat', enabled: true)

    service = described_class.new(article)

    expect(service.instance_variable_get(:@model)).to eq('gemini-3-flash')
    expect(service.send(:resolver_kind)).to eq('chat')
  end
end
