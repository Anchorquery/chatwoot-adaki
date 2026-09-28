class SuperAdmin::AccountUsersController < SuperAdmin::ApplicationController
  # Overwrite any of the RESTful controller actions to implement custom behavior
  # For example, you may want to send an email after a foo is updated.
  #

  # Since account/user page - account user role attribute links to the show page
  # Handle with a redirect to the user show page
  def show
    redirect_to super_admin_user_path(requested_resource.user)
  end

  # Upserts the membership so the form can also change the role of a user who
  # already belongs to the account.
  def create
    attributes = resource_params
    resource = resource_class.find_or_initialize_by(account_id: attributes[:account_id], user_id: attributes[:user_id])
    resource.assign_attributes(attributes.merge(role_attributes(attributes.delete(:role))))
    authorize_resource(resource)

    notice =  resource.save ? translate_with_resource('create.success') : resource.errors.full_messages.first
    redirect_back(fallback_location: [namespace, resource.account], notice: notice)
  end

  def destroy
    if requested_resource.destroy
      flash[:notice] = translate_with_resource('destroy.success')
    else
      flash[:error] = requested_resource.errors.full_messages.join('<br/>')
    end
    redirect_back(fallback_location: [namespace, requested_resource.account])
  end

  private

  # AccountRoleField submits either a built-in role or `custom_<id>`; a custom
  # role always sits on top of the agent role.
  def role_attributes(role)
    return { role: role, custom_role_id: nil } unless role.to_s.start_with?(AccountRoleField::CUSTOM_PREFIX)

    { role: :agent, custom_role_id: role.delete_prefix(AccountRoleField::CUSTOM_PREFIX) }
  end

  # Override this method to specify custom lookup behavior.
  # This will be used to set the resource for the `show`, `edit`, and `update`
  # actions.
  #
  # def find_resource(param)
  #   Foo.find_by!(slug: param)
  # end

  # The result of this lookup will be available as `requested_resource`

  # Override this if you have certain roles that require a subset
  # this will be used to set the records shown on the `index` action.
  #
  # def scoped_resource
  #   if current_user.super_admin?
  #     resource_class
  #   else
  #     resource_class.with_less_stuff
  #   end
  # end

  # Override `resource_params` if you want to transform the submitted
  # data before it's persisted. For example, the following would turn all
  # empty values into nil values. It uses other APIs such as `resource_class`
  # and `dashboard`:
  #
  # def resource_params
  #   params.require(resource_class.model_name.param_key).
  #     permit(dashboard.permitted_attributes).
  #     transform_values { |value| value == "" ? nil : value }
  # end

  # See https://administrate-prototype.herokuapp.com/customizing_controller_actions
  # for more information
end
