class CreatePlatformCredentials < ActiveRecord::Migration[7.0]
  def change
    create_table :platform_credentials do |t|
      t.references :account, null: true, foreign_key: true
      t.string :owner_type
      t.bigint :owner_id

      t.string :provider, null: false
      t.string :purpose, null: false
      t.string :name, null: false
      t.string :key, null: false
      t.string :auth_type, null: false

      t.jsonb :encrypted_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.integer :status, null: false, default: 0
      t.bigint :created_by_id
      t.bigint :updated_by_id

      t.datetime :last_used_at
      t.datetime :last_validated_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :platform_credentials, [:account_id, :key], unique: true
    add_index :platform_credentials, [:account_id, :provider, :purpose]
    add_index :platform_credentials, [:owner_type, :owner_id]
    add_index :platform_credentials, :status
    add_index :platform_credentials, :expires_at
  end
end
