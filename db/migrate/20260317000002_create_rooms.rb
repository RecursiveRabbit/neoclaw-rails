class CreateRooms < ActiveRecord::Migration[8.1]
  def change
    create_table :rooms do |t|
      t.string :matrix_room_id, null: false, index: { unique: true }
      t.string :name
      t.string :slug, index: true
      t.string :spawn_policy, default: "on_mention"
      t.integer :timeout_seconds, default: 600
      t.timestamps
    end
  end
end
