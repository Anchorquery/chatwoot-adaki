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

      context 'with attachments' do
        # sample.mp4 padded with zeros: still detected as video/mp4.
        def padded_upload(asset, size, content_type)
          file = Tempfile.new(['upload', File.extname(asset)])
          file.binmode
          file.write(File.binread(Rails.root.join('spec/assets', asset)))
          file.write("\0" * (size - file.size))
          file.rewind
          Rack::Test::UploadedFile.new(file.path, content_type)
        end

        def create_with(upload)
          post "/api/v1/accounts/#{account.id}/campaigns",
               params: { campaign: { inbox_id: inbox.id, title: 'test', message: 'test message', attachments: [upload] } },
               headers: administrator.create_new_auth_token
        end

        it 'stores the file of an attachment sent on create' do
          create_with(fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png'))

          campaign = Campaign.last
          blob = campaign.attachments.first.blob
          expect(campaign.display_id).to be_present
          expect(blob.service.exist?(blob.key)).to be(true)
        end

        it 'accepts an MP4 video above the old 16 MB limit' do
          create_with(padded_upload('sample.mp4', 20.megabytes, 'video/mp4'))

          expect(response).to have_http_status(:success)
          expect(Campaign.last.attachments.count).to eq(1)
        end

        it 'rejects an MP4 video above 64 MB' do
          create_with(padded_upload('sample.mp4', 64.megabytes + 1, 'video/mp4'))

          expect(response).to have_http_status(:unprocessable_entity)
          expect(Campaign.count).to eq(0)
        end

        it 'accepts a PDF above the old 16 MB limit' do
          create_with(Rack::Test::UploadedFile.new(Rails.root.join('spec/assets/large_file.pdf'), 'application/pdf'))

          expect(response).to have_http_status(:success)
        end

        it 'keeps images at 5 MB' do
          create_with(padded_upload('sample.png', 5.megabytes + 1, 'image/png'))

          expect(response).to have_http_status(:unprocessable_entity)
        end
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

  describe 'GET /api/v1/accounts/{account.id}/campaigns/:id/results' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:api_inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
    let(:contacts) { create_list(:contact, 4, account: account) }
    let!(:campaign) do
      sent, no_whatsapp, timeout = contacts.first(3).map { |c| c.id.to_s }
      create(:campaign, account: account, inbox: api_inbox, campaign_status: :running,
                        delivery_state: {
                          'contact_ids' => contacts.map(&:id), 'total_contacts' => 4, 'processed_index' => 3,
                          'sent_count' => 1, 'failed_count' => 2,
                          'recipients' => {
                            sent => { 'status' => 'sent' },
                            no_whatsapp => { 'status' => 'failed', 'error' => '500: Number not on WhatsApp', 'retryable' => false },
                            timeout => { 'status' => 'failed', 'error' => '500 Internal Server Error' }
                          }
                        })
    end

    def results(params = {})
      get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/results",
          params: params, headers: administrator.create_new_auth_token, as: :json
    end

    it 'tells groups apart from contacts and filters by type' do
      contacts.last.update!(identifier: '120363000000000001@g.us', name: 'Vecinos (GROUP)')

      results
      expect(response.parsed_body['stats']['type_counts']).to eq('group' => 1, 'channel' => 0, 'contact' => 3)

      results(type: 'group')
      expect(response.parsed_body['contacts'].pluck('id', 'recipient_type')).to eq([[contacts.last.id, 'group']])
    end

    it 'groups failures by reason and counts the recipients not processed yet' do
      results

      stats = response.parsed_body['stats']
      expect(stats['pending_count']).to eq(1)
      expect(stats['failure_reasons']).to contain_exactly(
        { 'error' => '500: Number not on WhatsApp', 'count' => 1, 'retryable' => false },
        { 'error' => '500 Internal Server Error', 'count' => 1, 'retryable' => true }
      )
    end

    it 'lists only the recipients not processed yet with the pending filter' do
      results(status: 'pending')

      expect(response.parsed_body['contacts'].pluck('id')).to eq([contacts.last.id])
    end

    it 'tells which failed recipients can be retried' do
      results(status: 'failed')

      retryable = response.parsed_body['contacts'].to_h { |c| [c['id'], c['retryable']] }
      expect(retryable).to eq(contacts[1].id => false, contacts[2].id => true)
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
        campaign.update!(delivery_state: campaign.delivery_state.merge('contact_ids' => [1, 3], 'total_contacts' => 2))
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

    context 'when the campaign stopped before reaching every recipient' do
      let(:recipients) { { '1' => { 'status' => 'sent' } } }

      it 'sends to the pending ones even without failures' do
        campaign.update!(delivery_state: campaign.delivery_state.merge('processed_index' => 1, 'failed_count' => 0))

        expect { retry_failed }.to have_enqueued_job(Campaigns::ProcessBatchJob)
        expect(response.parsed_body).to include('retry_count' => 2, 'failed_count' => 0, 'pending_count' => 2)
        state = campaign.reload.delivery_state
        expect(state['contact_ids']).to eq([1, 2, 3])
        expect(state['processed_index']).to eq(1)
        expect(campaign).to be_running
      end
    end

    it 'only retries failures when asked to' do
      campaign.update!(delivery_state: campaign.delivery_state.merge('contact_ids' => [1, 2, 3, 4]))

      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/retry_failed",
           params: { scope: 'failed' }, headers: administrator.create_new_auth_token, as: :json

      expect(response.parsed_body).to include('failed_count' => 1, 'pending_count' => 0)
      expect(campaign.reload.delivery_state['deferred_contact_ids']).to eq([4])
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
