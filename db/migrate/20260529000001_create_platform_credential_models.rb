class CreatePlatformCredentialModels < ActiveRecord::Migration[7.0]
  def change
    create_table :platform_credential_models do |t|
      t.references :credential,
                   null: false,
                   foreign_key: { to_table: :platform_credentials, on_delete: :cascade }

      t.string :slug, null: false
      t.string :display_name, null: false
      t.string :kind, null: false, default: 'chat'

      t.jsonb :capabilities, null: false, default: []

      t.integer :context_window
      t.integer :max_output_tokens

      t.decimal :input_price_per_million,  precision: 12, scale: 4
      t.decimal :output_price_per_million, precision: 12, scale: 4

      t.date :data_cutoff_at

      t.text :description

      t.boolean :obsolete, null: false, default: false
      t.boolean :enabled,  null: false, default: false

      t.jsonb :raw_metadata, null: false, default: {}

      t.datetime :synced_at

      t.timestamps
    end

    add_index :platform_credential_models, [:credential_id, :slug], unique: true
    add_index :platform_credential_models, :kind
    add_index :platform_credential_models, :enabled
  end
end
