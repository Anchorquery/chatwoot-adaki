FactoryBot.define do
  factory :article, class: 'Article' do
    account
    category { nil }
    # Article#ensure_account_id always overwrites account_id from portal.account_id
    # on save, so portal must belong to the same account as the article —
    # otherwise an explicit `account:` override here is silently discarded.
    portal { association :portal, account: account }
    locale { 'en' }
    association :author, factory: :user
    title { "#{Faker::Movie.title} #{SecureRandom.hex}" }
    content { 'MyText' }
    description { 'MyDescrption' }
    status { :published }
    views { 0 }
  end
end
