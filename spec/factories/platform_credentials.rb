FactoryBot.define do
  factory :platform_credential, class: 'Platform::Credential' do
    association :account
    provider { 'openai' }
    purpose { 'ai_provider' }
    sequence(:name) { |n| "Credential #{n}" }
    sequence(:key) { |n| "#{provider}.cred_#{n}" }
    auth_type { 'api_key' }
    payload { { api_key: 'test-api-key' } }
    metadata { {} }
    status { :active }

    trait :gemini do
      provider { 'gemini' }
      payload { { api_key: 'AIzaSy-test-gemini-key' } }
    end

    trait :openai do
      provider { 'openai' }
      payload { { api_key: 'sk-test-openai-key' } }
    end
  end
end
