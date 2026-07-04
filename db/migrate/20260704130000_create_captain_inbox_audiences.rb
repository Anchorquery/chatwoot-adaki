class CreateCaptainInboxAudiences < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_inbox_audiences do |t|
      t.references :inbox, null: false, index: true
      t.references :captain_assistant, null: false, index: true
      t.jsonb :group_jids, null: false, default: []
      t.jsonb :label_titles, null: false, default: []

      t.timestamps
    end
  end
end
