class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false, index: { unique: true }
      t.text :value
      t.string :value_type, default: "string"
      t.string :group, null: false
      t.text :description
      t.timestamps
    end
  end
end
