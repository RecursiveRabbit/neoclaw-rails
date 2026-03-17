class CreateAgentRoomConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_room_configs do |t|
      t.references :agent_config, null: false, foreign_key: true
      t.string :channel, null: false
      t.json :extra_services, default: []     # additional services for THIS agent in THIS room
      t.string :model_override                 # override model for this pairing
      t.text :notes
      t.timestamps
    end

    add_index :agent_room_configs, [:agent_config_id, :channel], unique: true
  end
end
