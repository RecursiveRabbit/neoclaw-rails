class CreateAgentConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_configs do |t|
      t.string :identity, null: false, index: { unique: true }
      t.string :repo                          # Forgejo repo path
      t.string :model, default: "claude-opus-4-6"
      t.boolean :singleton, default: false
      t.json :base_services, default: []      # ["git", "ssh", "valley"]
      t.json :channel_overrides, default: {}  # {"art": ["comfyui"]}
      t.integer :idle_timeout, default: 480   # seconds
      t.text :notes
      t.timestamps
    end
  end
end
