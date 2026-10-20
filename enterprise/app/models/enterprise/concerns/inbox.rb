module Enterprise::Concerns::Inbox
  extend ActiveSupport::Concern

  included do
    has_one :captain_inbox, dependent: :destroy, class_name: 'CaptainInbox'
    has_one :captain_assistant,
            through: :captain_inbox,
            class_name: 'Captain::Assistant'
    has_many :captain_inbox_audiences, dependent: :destroy
    has_many :inbox_capacity_limits, dependent: :destroy
    has_many :calls, dependent: :destroy_async

    after_create_commit :grant_whatsapp_operators
  end

  private

  # Un número de WhatsApp nuevo lo ven enseguida quienes operan WhatsApp.
  def grant_whatsapp_operators
    CustomRoles::WhatsappInboxAccessService.grant_for_inbox(self)
  end
end
