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

  # FlagShihTzu's bit-column only stores true/false: it cannot represent
  # "never touched" vs "explicitly set to false", so `feature_enabled?`
  # could not tell apart an account that never set a flag from one that
  # explicitly disabled it. This module tracks, per bit, whether it was
  # ever written, in a parallel bitmask column (feature_overrides /
  # feature_overrides_2 mirror feature_flags / feature_flags_2 bit-for-bit).
  # `enable_flag`/`disable_flag` are FlagShihTzu's only two primitives that
  # ever mutate a flag bit (the generated `feature_x=` setter, `enable_flag`/
  # `disable_flag` bang methods, and `select_all_flags`/`unselect_all_flags`
  # all funnel through them), so hooking these two catches every write path,
  # including the super-admin `selected_feature_flags=` bulk form submit.
  module OverrideTracker
    def enable_flag(flag, colmn = nil)
      mark_feature_overridden(flag, colmn)
      super
    end

    def disable_flag(flag, colmn = nil)
      mark_feature_overridden(flag, colmn)
      super
    end

    def feature_overridden?(name)
      flag_name = "feature_#{name}".to_sym
      colmn = self.class.determine_flag_colmn_for(flag_name)
      bit = self.class.flag_mapping[colmn][flag_name]
      send(override_attribute_for(colmn)).anybits?(bit)
    rescue FlagShihTzu::NoSuchFlagException
      false
    end

    private

    def mark_feature_overridden(flag, colmn)
      colmn ||= self.class.determine_flag_colmn_for(flag)
      return unless colmn.to_s.start_with?('feature_flags')

      bit = self.class.flag_mapping[colmn][flag]
      override_attr = override_attribute_for(colmn)
      send("#{override_attr}=", send(override_attr) | bit)
    end

    def override_attribute_for(colmn)
      colmn == 'feature_flags_2' ? :feature_overrides_2 : :feature_overrides
    end
  end

  # flag_shih_tzu define `selected_feature_flags` y `selected_feature_flags=`
  # directamente sobre la clase incluyente via class_eval, por lo que metodos
  # definidos en el module body de Featurable quedan en el ancestor chain por
  # debajo y nunca ganan el lookup. Usamos `prepend` con este module: garantiza
  # que el override se invoca primero independientemente del orden de carga.
  module SelectedFlagsRouter
    def selected_feature_flags=(chosen_flags)
      unselect_all_flags('feature_flags')
      unselect_all_flags('feature_flags_2') if self.class.flag_mapping.key?('feature_flags_2')
      return if chosen_flags.nil?

      chosen_flags.each do |flag|
        next if flag.blank?

        # `enable_flag` con colmn=nil delega en `determine_flag_colmn_for`
        # para enrutar el flag a la columna correcta.
        enable_flag(flag.to_sym)
      end
    end

    def selected_feature_flags
      primary = selected_flags('feature_flags')
      return primary unless self.class.flag_mapping.key?('feature_flags_2')

      primary + selected_flags('feature_flags_2')
    end
  end

  included do
    include FlagShihTzu
    has_flags FEATURES_PRIMARY.merge(column: 'feature_flags').merge(QUERY_MODE)
    has_flags FEATURES_SECONDARY.merge(column: 'feature_flags_2').merge(QUERY_MODE) if FEATURES_SECONDARY.any?

    prepend SelectedFlagsRouter
    prepend OverrideTracker

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

    return send(flag_method) if feature_overridden?(name)

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
