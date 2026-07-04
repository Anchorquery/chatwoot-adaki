class AddFeatureOverridesToAccounts < ActiveRecord::Migration[7.1]
  def change
    # Mirrors feature_flags / feature_flags_2 bit-for-bit: tracks which bits
    # were explicitly written (via enable/disable), so `feature_enabled?` can
    # tell "never touched" apart from "explicitly set to false" and correctly
    # fall back to the config/features.yml default only in the former case.
    add_column :accounts, :feature_overrides, :bigint, default: 0, null: false
    add_column :accounts, :feature_overrides_2, :bigint, default: 0, null: false
  end
end
