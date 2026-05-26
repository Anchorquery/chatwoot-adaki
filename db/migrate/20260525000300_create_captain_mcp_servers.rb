class CreateCaptainMcpServers < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_mcp_servers do |t|
      t.references :account, null: false, foreign_key: true
      t.references :platform_credential, foreign_key: true

      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :transport_type, null: false, default: 'streamable_http'
      t.text :endpoint_url
      t.text :command
      t.jsonb :command_args, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.integer :timeout_seconds, null: false, default: 20
      t.jsonb :tools_cache, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.text :last_error
      t.datetime :last_discovered_at

      t.timestamps
    end

    add_index :captain_mcp_servers, [:account_id, :slug], unique: true
    add_index :captain_mcp_servers, [:account_id, :enabled]
  end
end
