class SuperAdmin::CustomRolesController < SuperAdmin::EnterpriseBaseController
  private

  # Drops the placeholder sent by the permission checkboxes and stores "no
  # sidebar profile" as nil, which is what the model validation accepts.
  def resource_params
    super.tap do |attributes|
      attributes[:permissions] = Array(attributes[:permissions]).compact_blank if attributes.key?(:permissions)
      attributes[:sidebar_profile] = attributes[:sidebar_profile].presence if attributes.key?(:sidebar_profile)
    end
  end
end
