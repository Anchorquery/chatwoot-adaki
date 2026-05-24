require 'rails_helper'

RSpec.describe 'Adaki GDPR API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, name: 'Jane Doe', email: 'jane@example.com', phone_number: '+34600111222') }

  describe 'POST /api/v1/accounts/:id/adaki/gdpr/pseudonymize_contact' do
    context 'unauthenticated' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
             params: { contact_id: contact.id }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'as agent (non-admin)' do
      it 'returns forbidden' do
        post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
             params: { contact_id: contact.id },
             headers: agent.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
      end
    end

    context 'as admin' do
      it 'pseudonymizes the contact PII' do
        post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
             params: { contact_id: contact.id, reason: 'right_to_be_forgotten' },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:ok)
        contact.reload
        expect(contact.name).to start_with('ghost-')
        expect(contact.email).to be_nil
        expect(contact.phone_number).to be_nil
        expect(contact.identifier).to be_nil
        expect(contact.additional_attributes['pseudonymized_at']).to be_present
      end

      it 'writes audit entry without PII' do
        expect do
          post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
               params: { contact_id: contact.id, reason: 'gdpr_request' },
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Adaki::AuditLogEntry, :count).by(1)

        entry = Adaki::AuditLogEntry.last
        expect(entry.action).to eq('gdpr.contact.pseudonymized')
        expect(entry.payload.to_json).not_to include('jane@example.com')
        expect(entry.payload.to_json).not_to include('Jane Doe')
      end

      it 'returns 404 for nonexistent contact' do
        post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
             params: { contact_id: 999_999 },
             headers: admin.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:not_found)
      end

      it 'cannot pseudonymize a contact from another account' do
        other_contact = create(:contact, account: create(:account))
        post "/api/v1/accounts/#{account.id}/adaki/gdpr/pseudonymize_contact",
             params: { contact_id: other_contact.id },
             headers: admin.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
