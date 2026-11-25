class CreateCoveSheets < ActiveRecord::Migration[8.1]
  def change
    create_table :cove_sheets do |t|
      t.string  :slug, null: false
      t.string  :name, null: false
      t.string  :kind, null: false, default: "agent"
      t.string  :harness
      t.string  :model
      t.string  :repo
      t.string  :image
      t.text    :command
      t.string  :listen
      t.string  :pod_ip, default: ""
      t.string  :pubkey, default: ""
      t.string  :wg_port, default: ""
      # tools and services are lists, and `extra` is everything this build has never
      # heard of. The old file-backed Sheet carried unknown keys through untouched by
      # law; a row has to do the same or an upgrade silently eats a field.
      t.text    :tools
      t.text    :services
      t.text    :extra
      t.timestamps
    end
    add_index :cove_sheets, :slug, unique: true
  end
end
