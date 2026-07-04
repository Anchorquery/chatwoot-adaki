require 'rails_helper'

RSpec.describe Featurable do
  let(:account) { create(:account) }

  # `inbound_emails` ships with `enabled: true` in config/features.yml.
  let(:default_enabled_feature) { :inbound_emails }
  # `conversation_unread_counts` ships with `enabled: false`.
  let(:default_disabled_feature) { :conversation_unread_counts }

  describe '#feature_enabled?' do
    context 'when the flag was never explicitly set' do
      it 'falls back to the config/features.yml default when it is true' do
        expect(account.feature_enabled?(default_enabled_feature)).to be true
      end

      it 'falls back to the config/features.yml default when it is false' do
        expect(account.feature_enabled?(default_disabled_feature)).to be false
      end
    end

    context 'when a default-enabled flag was explicitly disabled' do
      it 'returns false instead of the yaml default' do
        account.disable_features!(default_enabled_feature)
        account.reload

        expect(account.feature_enabled?(default_enabled_feature)).to be false
      end
    end

    context 'when a default-disabled flag was explicitly enabled' do
      it 'returns true instead of the yaml default' do
        account.enable_features!(default_disabled_feature)
        account.reload

        expect(account.feature_enabled?(default_disabled_feature)).to be true
      end
    end

    context 'when an explicitly disabled flag is re-enabled' do
      it 'reflects the latest explicit value' do
        account.disable_features!(default_enabled_feature)
        account.enable_features!(default_enabled_feature)
        account.reload

        expect(account.feature_enabled?(default_enabled_feature)).to be true
      end
    end

    context 'when going through the super admin bulk selected_feature_flags= form path' do
      it 'disables a default-enabled feature that is left unchecked' do
        account.selected_feature_flags = ["feature_#{default_disabled_feature}"]
        account.save!
        account.reload

        expect(account.feature_enabled?(default_enabled_feature)).to be false
        expect(account.feature_enabled?(default_disabled_feature)).to be true
      end
    end
  end
end
