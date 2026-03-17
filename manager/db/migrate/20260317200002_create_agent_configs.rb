class CreateAgentConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_configs do |t|
      t.string :identity, null: false, index: { unique: true }
      t.string :repo
      t.string :model, default: "claude-opus-4-6"
      t.boolean :singleton, default: false
      t.json :base_services, default: []
      t.json :channel_overrides, default: {}
      t.integer :idle_timeout, default: 480
      t.text :system_prompt
      t.text :notes
      t.timestamps
    end
  end
end
