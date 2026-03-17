class CreateContainers < ActiveRecord::Migration[8.1]
  def change
    create_table :containers do |t|
      t.string :instance_name, null: false, index: { unique: true }
      t.string :identity, null: false
      t.string :channel, null: false
      t.string :container_id              # podman container ID
      t.string :wg_address                # 10.0.1.X
      t.string :wg_pubkey
      t.string :state, default: "starting"
      t.json :provisioned_services, default: []
      t.float :context_usage, default: 0.0
      t.datetime :last_message_at
      t.datetime :last_health_at
      t.timestamps
    end

    add_index :containers, :state
    add_index :containers, :identity
  end
end
