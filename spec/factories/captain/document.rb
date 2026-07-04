FactoryBot.define do
  factory :captain_document, class: 'Captain::Document' do
    name { Faker::File.file_name }
    external_link { Faker::Internet.unique.url }
    content { Faker::Lorem.paragraphs.join("\n\n") }
    association :account
    # Captain::Document#ensure_account_id always overwrites account_id from
    # assistant.account_id on save, so the assistant MUST belong to the same
    # account as the document — otherwise an explicit `account:` override here
    # is silently discarded in favor of a mismatched auto-generated one.
    assistant { association :captain_assistant, account: account }
  end
end
