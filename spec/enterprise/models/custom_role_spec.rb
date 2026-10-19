require 'rails_helper'

RSpec.describe CustomRole, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_users).dependent(:nullify) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }

    it 'accepts every permission of the catalog' do
      role = build(:custom_role, permissions: described_class::PERMISSIONS)

      expect(role).to be_valid
    end

    it 'rejects an unknown permission' do
      role = build(:custom_role, permissions: %w[campaign_manage make_coffee])

      expect(role).not_to be_valid
    end
  end

  describe 'permission catalog' do
    it 'lists every permission in exactly one section' do
      grouped = described_class::PERMISSION_GROUPS.values.flatten

      expect(grouped).to match_array(described_class::PERMISSIONS)
      expect(grouped.uniq.size).to eq(grouped.size)
    end

    it 'only offers templates made of known permissions' do
      described_class::PRESETS.each_value do |permissions|
        expect(described_class::PERMISSIONS).to include(*permissions)
      end
    end
  end

  describe '#effective_permissions' do
    it 'returns the ticked permissions' do
      role = build(:custom_role, permissions: %w[campaign_manage contact_manage])

      expect(role.effective_permissions).to match_array(%w[campaign_manage contact_manage])
    end

    it 'expands the legacy agent_settings_manage into its granular permissions' do
      role = build(:custom_role, permissions: %w[agent_settings_manage])

      expect(role.effective_permissions).to include(
        'agent_settings_manage', 'inbox_manage', 'agent_manage', 'team_manage', 'label_manage', 'assignment_manage'
      )
    end

    it 'still resolves a legacy sidebar profile' do
      role = build(:custom_role, permissions: %w[report_manage], sidebar_profile: 'communication')

      expect(role.effective_permissions).to include('report_manage', 'campaign_manage', 'channel_operate')
    end
  end

  describe 'account user permissions' do
    it 'exposes the effective permissions plus the custom role marker' do
      account = create(:account)
      role = create(:custom_role, account: account, permissions: %w[campaign_manage])
      account_user = create(:account_user, account: account, custom_role: role)

      expect(account_user.permissions).to match_array(%w[campaign_manage custom_role])
    end
  end
end
