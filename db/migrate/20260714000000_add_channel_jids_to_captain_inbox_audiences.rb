class AddChannelJidsToCaptainInboxAudiences < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_inbox_audiences, :channel_jids, :jsonb, null: false, default: []
  end
end
