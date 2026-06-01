FactoryBot.define do
  factory :platform_credential_model, class: 'Platform::CredentialModel' do
    association :credential, factory: :platform_credential
    sequence(:slug) { |n| "model-#{n}" }
    sequence(:display_name) { |n| "Model #{n}" }
    kind { 'chat' }
    enabled { true }

    trait :disabled do
      enabled { false }
    end
  end
end
