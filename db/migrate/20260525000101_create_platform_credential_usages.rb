class CreatePlatformCredentialUsages < ActiveRecord::Migration[7.0]
  def change
    create_table :platform_credential_usages do |t|
      t.references :account, null: true, foreign_key: true
      t.references :platform_credential, null: false, foreign_key: true

      t.string :used_by_type
      t.bigint :used_by_id
      t.string :operation, null: false
      t.string :status, null: false
      t.string :error_code

      t.jsonb :context, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :platform_credential_usages, [:platform_credential_id, :created_at], name: 'idx_pcu_on_platform_credential_id_created_at'
    add_index :platform_credential_usages, [:account_id, :created_at], name: 'idx_pcu_on_account_id_created_at'
    add_index :platform_credential_usages, [:used_by_type, :used_by_id], name: 'idx_pcu_on_used_by_type_and_id'
  end
end
