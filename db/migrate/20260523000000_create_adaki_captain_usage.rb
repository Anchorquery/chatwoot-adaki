class CreateAdakiCaptainUsage < ActiveRecord::Migration[7.1]
  def change
    create_table :adaki_captain_usages do |t|
      t.references :account, null: false, foreign_key: true
      t.date :period, null: false
      t.integer :request_count, null: false, default: 0
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.timestamps
    end
    add_index :adaki_captain_usages, [:account_id, :period], unique: true

    add_column :accounts, :adaki_captain_monthly_limit, :integer
  end
end
