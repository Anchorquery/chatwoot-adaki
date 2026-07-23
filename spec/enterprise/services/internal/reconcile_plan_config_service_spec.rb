require 'rails_helper'

RSpec.describe Internal::ReconcilePlanConfigService do
  describe '#perform' do
    let(:service) { described_class.new }

    # Adaki is a disconnected fork with all premium features permanently
    # unlocked. This service used to reset local branding config back to
    # "Chatwoot" whenever the (unreachable) upstream hub resolved the plan to
    # 'community', which happens by default on every self-hosted install.
    # It's now a no-op that only clears the stale reset warning.
    it 'does not modify installation config regardless of pricing plan' do
      create(:installation_config, name: 'INSTALLATION_NAME', value: 'custom-name')
      create(:installation_config, name: 'LOGO', value: '/custom-path/logo.svg')

      service.perform

      expect(InstallationConfig.find_by(name: 'INSTALLATION_NAME').value).to eq('custom-name')
      expect(InstallationConfig.find_by(name: 'LOGO').value).to eq('/custom-path/logo.svg')
    end

    it 'does not disable any account features' do
      account = create(:account)
      account.enable_features!('disable_branding', 'audit_logs', 'captain_integration')

      service.perform

      expect(account.reload.enabled_features.keys).to include('captain_integration', 'disable_branding', 'audit_logs')
    end

    it 'clears the premium config reset warning' do
      Redis::Alfred.set(Redis::Alfred::CHATWOOT_INSTALLATION_CONFIG_RESET_WARNING, true)

      service.perform

      expect(Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_CONFIG_RESET_WARNING)).to be_nil
    end
  end
end
