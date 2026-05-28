class AddSettingsToCaptainInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_inboxes, :settings, :jsonb, default: {}, null: false
  end
end
