# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Macro do
  let(:account) { create(:account) }
  let!(:macro) { create(:macro, account: account) }

  describe '#set_visibility' do
    let(:user) { create(:user, account: account, role: :agent) }
    let(:account_user) { account.account_users.find_by(user_id: user.id) }

    before do
      Current.user = user
      Current.account = account
    end

    after do
      Current.user = nil
      Current.account = nil
    end

    it 'lets a custom role with macro_manage share macros' do
      account_user.update!(custom_role: create(:custom_role, account: account, permissions: %w[macro_manage]))

      macro.set_visibility(user, { visibility: :global })

      expect(macro.visibility).to eq('global')
    end

    it 'keeps macros personal for a custom role without macro_manage' do
      account_user.update!(custom_role: create(:custom_role, account: account, permissions: %w[conversation_manage]))

      macro.set_visibility(user, { visibility: :global })

      expect(macro.visibility).to eq('personal')
    end
  end

  describe 'audit log' do
    context 'when macro is created' do
      it 'has associated audit log created' do
        expect(Audited::Audit.where(auditable_type: 'Macro', action: 'create').count).to eq 1
      end
    end

    context 'when macro is updated' do
      it 'has associated audit log created' do
        macro.update(name: 'awesome macro')
        expect(Audited::Audit.where(auditable_type: 'Macro', action: 'update').count).to eq 1
      end
    end

    context 'when macro is deleted' do
      it 'has associated audit log created' do
        macro.destroy!
        expect(Audited::Audit.where(auditable_type: 'Macro', action: 'destroy').count).to eq 1
      end
    end
  end
end
