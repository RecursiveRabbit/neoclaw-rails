class CreateListeners < ActiveRecord::Migration[8.1]
  def change
    create_table :listeners do |t|
      t.references :identity, null: false, foreign_key: true
      t.string :channel_slug, null: false
      t.timestamps
    end

    add_index :listeners, [:identity_id, :channel_slug], unique: true
  end
end
