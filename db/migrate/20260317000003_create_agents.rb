class CreateAgents < ActiveRecord::Migration[8.1]
  def change
    create_table :agents do |t|
      t.references :identity, null: false, foreign_key: true
      t.references :room, null: false, foreign_key: true
      t.string :instance_name, null: false, index: { unique: true }
      t.string :wg_address
      t.string :wg_pubkey
      t.string :state, default: "resolving"  # resolving, alive, releasing
      t.datetime :last_message_at
      t.float :context_usage, default: 0.0
      t.timestamps
    end
  end
end
