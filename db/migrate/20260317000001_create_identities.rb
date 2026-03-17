class CreateIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :identities do |t|
      t.string :name, null: false, index: { unique: true }
      t.boolean :singleton, default: false
      t.text :system_prompt
      t.timestamps
    end
  end
end
