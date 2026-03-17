class CreateRoomConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :room_configs do |t|
      t.string :channel, null: false, index: { unique: true }
      t.json :extra_services, default: []      # services ALL agents get in this room
      t.string :model_default                   # override model for this room
      t.text :notes
      t.timestamps
    end
  end
end
