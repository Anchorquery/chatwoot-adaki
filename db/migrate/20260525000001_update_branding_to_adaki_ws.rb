class UpdateBrandingToAdakiWs < ActiveRecord::Migration[7.0]
  BRANDING_CONFIGS = {
    'INSTALLATION_NAME' => 'Adaki WS',
    'BRAND_NAME' => 'Adaki WS'
  }.freeze

  def up
    BRANDING_CONFIGS.each do |name, value|
      config = InstallationConfig.find_by(name: name)
      next unless config
      next if config.value == value

      config.update_columns(
        serialized_value: { value: value }.with_indifferent_access
      )
    end
    GlobalConfig.clear_cache
  end

  def down
    # no rollback - branding changes are intentional
  end
end
