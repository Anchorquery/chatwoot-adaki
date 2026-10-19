require 'rails_helper'

# Each section of the app is opened by its own permission, so a role can be
# given exactly the sections it needs.
RSpec.describe 'Granular custom role permissions', type: :policy do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:account_user) { account.account_users.find_by(user_id: user.id) }
  let(:context) { { user: user, account: account, account_user: account_user.reload } }

  def give(*permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    account_user.update!(custom_role: role)
  end

  {
    TeamPolicy => ['team_manage', %i[create? update? destroy?], Team],
    TeamMemberPolicy => ['team_manage', %i[create? update? destroy?], TeamMember],
    LabelPolicy => ['label_manage', %i[create? update? show? destroy?], Label],
    AssignmentPolicyPolicy => ['assignment_manage', %i[index? show? create? update? destroy?], AssignmentPolicy],
    AgentCapacityPolicyPolicy => ['assignment_manage', %i[index? show? create? update? destroy?], AgentCapacityPolicy],
    CampaignPolicy => ['campaign_manage', %i[index? show? create? update? destroy? clone? results? retry_failed? ai_generate?], Campaign],
    UserPolicy => ['agent_manage', %i[create?], User]
  }.each do |policy_class, (permission, actions, record_class)|
    describe policy_class do
      actions.each do |action|
        it "allows ##{action} with #{permission} only" do
          give(permission)
          expect(policy_class.new(context, record_class.new).public_send(action)).to be_truthy
        end

        it "denies ##{action} with any other section's permission" do
          give((CustomRole::PERMISSIONS - [permission]).first)
          expect(policy_class.new(context, record_class.new).public_send(action)).to be_falsey
        end
      end
    end
  end

  describe InboxPolicy do
    let(:inbox) { create(:inbox, account: account) }

    it 'lets inbox_manage configure any inbox' do
      give('inbox_manage')

      expect(described_class.new(context, inbox)).to be_update
      expect(described_class.new(context, inbox)).to be_create
      expect(described_class.new(context, inbox)).to be_destroy
    end

    it 'does not let team_manage touch inboxes' do
      give('team_manage')

      expect(described_class.new(context, inbox)).not_to be_update
    end

    it 'does not let channel_operate configure inboxes' do
      give('channel_operate')

      expect(described_class.new(context, inbox)).not_to be_update
      expect(described_class.new(context, inbox)).not_to be_create
      expect(described_class.new(context, inbox)).not_to be_evolution_logout
      expect(described_class.new(context, inbox)).not_to be_evolution_instance_settings
    end

    context 'with channel_operate' do
      before do
        give('channel_operate')
        allow(Current).to receive_messages(user: user, account: account)
      end

      it 'operates the WhatsApp session of an assigned inbox' do
        create(:inbox_member, user: user, inbox: inbox)

        policy = described_class.new(context, inbox)
        expect(policy).to be_evolution_connection_state
        expect(policy).to be_evolution_connect
        expect(policy).to be_evolution_restart
      end

      it 'cannot operate an inbox it is not assigned to' do
        policy = described_class.new(context, inbox)

        expect(policy).not_to be_evolution_connection_state
        expect(policy).not_to be_evolution_connect
        expect(policy).not_to be_evolution_restart
      end
    end
  end

  describe 'the legacy agent_settings_manage permission' do
    it 'keeps opening every team section' do
      give('agent_settings_manage')

      expect(TeamPolicy.new(context, Team.new)).to be_create
      expect(LabelPolicy.new(context, Label.new)).to be_create
      expect(AssignmentPolicyPolicy.new(context, AssignmentPolicy.new)).to be_create
      expect(InboxPolicy.new(context, create(:inbox, account: account))).to be_update
    end
  end

  describe 'inbox visibility' do
    it 'lists every inbox for inbox_manage and only assigned ones otherwise' do
      other = create(:inbox, account: account)
      assigned = create(:inbox, account: account)
      create(:inbox_member, user: user, inbox: assigned)
      allow(Current).to receive(:account).and_return(account)
      allow(Current).to receive(:user).and_return(user)

      give('campaign_manage')
      expect(InboxPolicy::Scope.new(context, Inbox).resolve).to contain_exactly(assigned)

      give('inbox_manage')
      expect(InboxPolicy::Scope.new(context, Inbox).resolve).to include(assigned, other)
    end
  end
end
