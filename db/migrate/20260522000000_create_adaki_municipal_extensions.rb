class CreateAdakiMunicipalExtensions < ActiveRecord::Migration[7.1]
  def change
    create_table :adaki_absences do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :coverage_user, foreign_key: { to_table: :users }
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.string :reason
      t.string :status, null: false, default: 'scheduled'
      t.jsonb :metadata, default: {}
      t.timestamps
    end
    add_index :adaki_absences, [:account_id, :start_at, :end_at]
    add_index :adaki_absences, [:user_id, :status]

    create_table :adaki_campaign_approvals do |t|
      t.references :campaign, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'pending'
      t.datetime :requested_at, null: false
      t.datetime :decided_at
      t.text :decision_note
      t.integer :recipient_count
      t.timestamps
    end
    add_index :adaki_campaign_approvals, [:campaign_id, :status]

    create_table :adaki_whatsapp_tier_snapshots do |t|
      t.references :channel_whatsapp, null: false, foreign_key: { to_table: :channel_whatsapp }
      t.integer :messaging_limit_tier
      t.integer :max_daily_conversations
      t.integer :conversations_sent_24h
      t.string :quality_rating
      t.string :status
      t.jsonb :raw_payload, default: {}
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :adaki_whatsapp_tier_snapshots, [:channel_whatsapp_id, :captured_at],
              name: 'idx_adaki_tier_snapshots_on_channel_captured'

    create_table :adaki_audit_log_entries do |t|
      t.references :account, null: false, foreign_key: true
      # nullify on user delete: audit entries must survive personnel turnover (legal retention).
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :action, null: false
      t.string :auditable_type
      t.bigint :auditable_id
      t.jsonb :payload, null: false, default: {}
      t.string :previous_hash
      t.string :hash_chain, null: false
      t.datetime :recorded_at, null: false
      t.timestamps
    end
    add_index :adaki_audit_log_entries, [:account_id, :recorded_at]
    add_index :adaki_audit_log_entries, [:auditable_type, :auditable_id]
    add_index :adaki_audit_log_entries, :hash_chain, unique: true

    add_column :channel_whatsapp, :messaging_tier, :integer
    add_column :channel_whatsapp, :quality_rating, :string
    add_column :channel_whatsapp, :daily_conversation_limit, :integer
    add_column :channel_whatsapp, :tier_checked_at, :datetime
    add_column :channel_whatsapp, :tier_locked, :boolean, default: false, null: false
    add_column :channel_whatsapp, :tier_lock_reason, :string

    add_column :campaigns, :requires_approval, :boolean, default: false, null: false
    add_column :campaigns, :approval_status, :string, default: 'not_required'
  end
end
