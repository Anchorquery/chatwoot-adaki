class Internal::ReconcilePlanConfigService
  # Adaki is a disconnected fork with all premium features permanently unlocked
  # (see enterprise/config/premium_features.yml). Remote plan reconciliation
  # against the upstream Chatwoot hub used to reset local branding (BRAND_NAME,
  # INSTALLATION_NAME, ...) back to "Chatwoot" on every daily run because this
  # instance can never resolve to a paid plan there. Disabled entirely.
  def perform
    remove_premium_config_reset_warning
  end

  private

  def remove_premium_config_reset_warning
    Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_CONFIG_RESET_WARNING)
  end
end
