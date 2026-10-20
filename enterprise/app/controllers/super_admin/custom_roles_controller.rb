class SuperAdmin::CustomRolesController < SuperAdmin::EnterpriseBaseController
  private

  # Drops the placeholder sent by the permission checkboxes.
  def resource_params
    super.tap do |attributes|
      attributes[:permissions] = Array(attributes[:permissions]).compact_blank if attributes.key?(:permissions)
    end
  end
end
