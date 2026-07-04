class Api::V1::Accounts::Adaki::GdprController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?

  def pseudonymize_contact
    contact_id = params.require(:contact_id)
    contact = Current.account.contacts.find(contact_id)

    pseudo_id = SecureRandom.hex(8)
    {
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier
    }

    Contact.transaction do
      contact.update!(
        name: "ghost-#{pseudo_id}",
        email: nil,
        phone_number: nil,
        identifier: nil,
        additional_attributes: { pseudonymized_at: Time.current.iso8601, pseudo_id: pseudo_id },
        custom_attributes: {}
      )
    end

    Adaki::AuditLogger.log(
      account: Current.account,
      user: Current.user,
      action: 'gdpr.contact.pseudonymized',
      auditable: contact,
      payload: {
        pseudo_id: pseudo_id,
        contact_id: contact.id,
        reason: params[:reason].to_s
        # Snapshot fields intentionally NOT stored — audit chain must not contain PII.
      }
    )

    render json: { ok: true, contact_id: contact.id, pseudo_id: pseudo_id }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Contact not found' }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
