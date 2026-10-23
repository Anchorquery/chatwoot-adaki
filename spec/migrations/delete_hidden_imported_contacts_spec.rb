require 'rails_helper'
require Rails.root.join('db/migrate/20261023120000_delete_hidden_imported_contacts.rb')

RSpec.describe DeleteHiddenImportedContacts do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let!(:outside_import) do
    create(:contact, account: account, name: 'Widget', custom_attributes: { 'phone' => '34600000001' }, created_at: 3.days.ago)
  end
  let!(:data_import) { create(:data_import, account: account, created_at: 1.hour.ago) }
  # What the old import left: only a name, the details kept under the CSV headers.
  let!(:ghost) { ghost_contact('Maddalen', 'teléfono' => '34648483423', 'Correo electrónico' => '00mugalde@gmail.com') }
  let!(:ghost_with_conversation) { ghost_contact('Alberto', 'teléfono' => '34630662371') }
  let!(:ghost_without_details) { ghost_contact('Sin datos', 'label' => 'lazkaokomunitatea') }
  let!(:visible_contact) { create(:contact, account: account, phone_number: '+34600111222') }

  before do
    create(:conversation, account: account, inbox: inbox, contact: ghost_with_conversation)
    data_import.update_columns(updated_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations
  end

  it 'deletes only the name-only contacts an import left without conversations' do
    described_class.new.up

    expect(Contact.exists?(ghost.id)).to be(false)
    expect(Contact.where(id: [outside_import, ghost_with_conversation, ghost_without_details, visible_contact].map(&:id)).count).to eq(4)
  end

  def ghost_contact(name, custom_attributes)
    create(:contact, account: account, name: name, email: nil, phone_number: nil, identifier: nil,
                     custom_attributes: custom_attributes, created_at: 30.minutes.ago)
  end
end
