require 'rails_helper'

RSpec.describe 'Campaigns API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/campaigns' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/campaigns"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }
      let(:inbox) { create(:inbox, account: account) }
      let!(:campaign) { create(:campaign, account: account, inbox: inbox, trigger_rules: { url: 'https://test.com' }) }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/campaigns",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns all campaigns to administrators' do
        get "/api/v1/accounts/#{account.id}/campaigns",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:payload].first[:id]).to eq(campaign.display_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows the campaign for administrators' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:id]).to eq(campaign.display_id)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates a new campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      it 'creates a new ongoing campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', trigger_rules: { url: 'https://test.com' } },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      it 'throws error when invalid url provided for ongoing campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', trigger_rules: { url: 'javascript' } },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'creates a new oneoff campaign' do
        twilio_sms = create(:channel_twilio_sms, account: account)
        twilio_inbox = create(:inbox, channel: twilio_sms, account: account)
        label1 = create(:label, account: account)
        label2 = create(:label, account: account)
        scheduled_at = 2.days.from_now

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               inbox_id: twilio_inbox.id, title: 'test', message: 'test message',
               scheduled_at: scheduled_at,
               audience: [{ type: 'Label', id: label1.id }, { type: 'Label', id: label2.id }]
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:campaign_type]).to eq('one_off')
        expect(response_data[:scheduled_at].present?).to be true
        expect(response_data[:scheduled_at]).to eq(scheduled_at.to_i)
        expect(response_data[:audience].pluck(:id)).to include(label1.id, label2.id)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:inbox) { create(:inbox, account: account) }
    let!(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates the campaign' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              headers: administrator.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      context 'with a one-off campaign scheduled in the future' do
        let(:api_inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
        let(:scheduled_at) { 1.day.from_now.change(usec: 0) }
        let!(:api_campaign) { create(:campaign, account: account, inbox: api_inbox, scheduled_at: scheduled_at) }

        def update_campaign(params)
          patch "/api/v1/accounts/#{account.id}/campaigns/#{api_campaign.display_id}",
                params: { campaign: params },
                headers: administrator.create_new_auth_token,
                as: :json
        end

        it 'starts it right away when immediate dispatch is on' do
          freeze_time do
            expect { update_campaign(delivery_settings: { immediate_dispatch: true }) }
              .to have_enqueued_job(Campaigns::TriggerOneoffCampaignJob).with(api_campaign)

            expect(response).to have_http_status(:success)
            expect(api_campaign.reload.scheduled_at).to eq(Time.current)
          end
        end

        it 'keeps the scheduled date when immediate dispatch is off' do
          expect { update_campaign(title: 'later') }.not_to have_enqueued_job(Campaigns::TriggerOneoffCampaignJob)

          expect(api_campaign.reload.scheduled_at).to eq(scheduled_at)
        end
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:inbox) { create(:inbox, account: account) }
    let!(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'return unauthorized if agent' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'delete campaign if admin' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               headers: administrator.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Campaign.exists?(campaign.display_id)).to be false
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/:id/retry_failed' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:api_inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
    let(:recipients) do
      { '1' => { 'status' => 'sent' }, '2' => { 'status' => 'failed', 'error' => 'timeout' },
        '3' => { 'status' => 'skipped', 'error' => 'no previous conversation' } }
    end
    let!(:campaign) do
      create(:campaign, account: account, inbox: api_inbox, campaign_status: :paused,
                        delivery_state: { 'contact_ids' => [1, 2, 3], 'total_contacts' => 3, 'processed_index' => 3,
                                          'sent_count' => 1, 'failed_count' => 1, 'recipients' => recipients })
    end

    def retry_failed
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/retry_failed",
           headers: administrator.create_new_auth_token,
           as: :json
    end

    it 'retries failed recipients and leaves skipped ones out' do
      retry_failed

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['retry_count']).to eq(1)

      state = campaign.reload.delivery_state
      expect(state['contact_ids']).to eq([1, 3, 2])
      expect(state['processed_index']).to eq(2)
      expect(state['recipients']['3']['status']).to eq('skipped')
      expect(state['recipients']).not_to have_key('2')
    end

    context 'when only skipped recipients are left' do
      let(:recipients) { { '1' => { 'status' => 'sent' }, '3' => { 'status' => 'skipped' } } }

      it 'does not write to them' do
        retry_failed

        expect(response).to have_http_status(:unprocessable_entity)
        expect(campaign.reload).to be_paused
      end
    end

    context 'when a recipient failed because the account is restricted (463)' do
      let(:recipients) do
        { '1' => { 'status' => 'sent' }, '2' => { 'status' => 'failed', 'error' => 'timeout' },
          '3' => { 'status' => 'failed', 'error' => '463', 'retryable' => false } }
      end

      it 'retries the other failures and leaves that one failed' do
        retry_failed

        expect(response.parsed_body['retry_count']).to eq(1)
        state = campaign.reload.delivery_state
        expect(state['contact_ids']).to eq([1, 3, 2])
        expect(state['recipients']['3']['status']).to eq('failed')
        expect(state['failed_count']).to eq(1)
      end
    end

    context 'when the campaign is already running' do
      before { campaign.update_columns(campaign_status: Campaign.campaign_statuses[:running]) } # rubocop:disable Rails/SkipsModelValidations

      it 'does not enqueue another batch' do
        expect { retry_failed }.not_to have_enqueued_job(Campaigns::ProcessBatchJob)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end
end
