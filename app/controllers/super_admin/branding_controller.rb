class SuperAdmin::BrandingController < SuperAdmin::ApplicationController
  BRANDING_KEYS = %w[
    INSTALLATION_NAME
    BRAND_NAME
    LOGO
    LOGO_DARK
    LOGO_THUMBNAIL
    BRAND_URL
    WIDGET_BRAND_URL
    TERMS_URL
    PRIVACY_URL
    DISPLAY_MANIFEST
  ].freeze

  def show
    @branding = BRANDING_KEYS.index_with do |key|
      ic = InstallationConfig.find_by(name: key)
      ic&.value
    end
  end

  def update
    errors = []
    params.fetch(:branding, {}).each do |key, value|
      next unless BRANDING_KEYS.include?(key)

      ic = InstallationConfig.where(name: key).first_or_create(value: value, locked: false)
      ic.value = value
      errors.concat(ic.errors.full_messages) unless ic.save
    end

    if errors.any?
      redirect_to super_admin_branding_path, alert: errors.join(', ')
    else
      redirect_to super_admin_branding_path, notice: 'Branding settings updated successfully.'
    end
  end
end
