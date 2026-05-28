module Featurable
  extend ActiveSupport::Concern

  QUERY_MODE = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze

  # PostgreSQL signed bigint cabe 63 bits utilizables (bit 64 desborda).
  # Bits 1..63 -> feature_flags. Bits 64+ -> feature_flags_2.
  MAX_BITS_PER_COLUMN = 63

  FEATURES_PRIMARY = {}
  FEATURES_SECONDARY = {}
  FEATURE_LIST.each_with_index do |feature, idx|
    key = "feature_#{feature['name']}".to_sym
    if idx < MAX_BITS_PER_COLUMN
      FEATURES_PRIMARY[idx + 1] = key
    else
      FEATURES_SECONDARY[idx - MAX_BITS_PER_COLUMN + 1] = key
    end
  end
  FEATURES_PRIMARY.freeze
  FEATURES_SECONDARY.freeze

  FEATURES = FEATURES_PRIMARY.merge(
    FEATURES_SECONDARY.transform_keys { |k| k + MAX_BITS_PER_COLUMN }
  ).freeze

  included do
    include FlagShihTzu
    has_flags FEATURES_PRIMARY.merge(column: 'feature_flags').merge(QUERY_MODE)
    has_flags FEATURES_SECONDARY.merge(column: 'feature_flags_2').merge(QUERY_MODE) if FEATURES_SECONDARY.any?

    # flag_shih_tzu define selected_feature_flags / selected_feature_flags=
    # directamente en la clase incluyente via class_eval. Los overrides en el
    # module body de Featurable quedan abajo en la cadena de ancestros y
    # nunca se ejecutan: el setter del gem rutea todo a 'feature_flags' y
    # lanza ArgumentError ("Invalid flag") cuando el flag pertenece a
    # 'feature_flags_2'. define_method dentro de included do registra los
    # overrides en la clase incluyente, sobreescribiendo los del gem.
    define_method(:selected_feature_flags=) do |chosen_flags|
      unselect_all_flags('feature_flags')
      unselect_all_flags('feature_flags_2') if self.class.flag_mapping.key?('feature_flags_2')
      next if chosen_flags.nil?

      chosen_flags.each do |flag|
        next if flag.blank?

        enable_flag(flag.to_sym)
      end
    end

    define_method(:selected_feature_flags) do
      primary = selected_flags('feature_flags')
      next primary unless self.class.flag_mapping.key?('feature_flags_2')

      primary + selected_flags('feature_flags_2')
    end

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
