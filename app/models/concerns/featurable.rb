module Featurable
  extend ActiveSupport::Concern

  QUERY_MODE = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze

  FEATURES = FEATURE_LIST.each_with_object({}) do |feature, result|
    result[result.keys.size + 1] = "feature_#{feature['name']}".to_sym
  end

  included do
    include FlagShihTzu
    has_flags FEATURES.merge(column: 'feature_flags').merge(QUERY_MODE)

    before_create :enable_default_features
  end

  def enable_features(*names)
    names.each do |name|
      send("feature_#{name}=", true)
    end
  end

  def enable_features!(*names)
    enable_features(*names)
    save
  end

  def disable_features(*names)
    names.each do |name|
      send("feature_#{name}=", false)
    end
  end

  def disable_features!(*names)
    disable_features(*names)
    save
  end

  # Premium / paid features are unlocked for every account by default.
  # Resolution order:
  #   1. If the account explicitly stored a flag (bit_operator) -> use it.
  #   2. Otherwise fall back to the YAML default in config/features.yml.
  # All previously "premium: true" features were flipped to "enabled: true"
  # at the YAML level, so they auto-enable here without needing a migration.
  def feature_enabled?(name)
    flag_method = "feature_#{name}?"
    return false unless respond_to?(flag_method)

    return true if send(flag_method)

    feature_default_enabled?(name)
  end

  def all_features
    FEATURE_LIST.pluck('name').index_with { |feature_name| feature_enabled?(feature_name) }
  end

  def feature_default_enabled?(name)
    feature = FEATURE_LIST.find { |f| f['name'] == name.to_s }
    feature.present? && feature['enabled'] == true
  end

  def enabled_features
    all_features.select { |_feature, enabled| enabled == true }
  end

  def disabled_features
    all_features.select { |_feature, enabled| enabled == false }
  end

  private

  def enable_default_features
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return true if config.blank?

    features_to_enabled = config.value.select { |f| f[:enabled] }.pluck(:name)
    enable_features(*features_to_enabled)
  end
end
