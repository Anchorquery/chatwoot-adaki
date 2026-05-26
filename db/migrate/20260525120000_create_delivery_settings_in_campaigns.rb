class CreateDeliverySettingsInCampaigns < ActiveRecord::Migration[7.1]
  def change
    change_table :campaigns, bulk: true do |t|
      t.jsonb :delivery_settings, default: {}
      t.jsonb :delivery_state, default: {}
    end
  end
end
