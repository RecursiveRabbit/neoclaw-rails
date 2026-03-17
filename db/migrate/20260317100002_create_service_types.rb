class CreateServiceTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :service_types do |t|
      t.string :name, null: false, index: { unique: true }  # "git", "ssh", "valley"
      t.string :wg_interface                  # "wg-git", "wg-valley"
      t.string :wg_ip                         # "10.0.0.3"
      t.integer :wg_listen_port               # 51823
      t.string :provision_type                # "forgejo", "ssh_key", "token", "none"
      t.json :provision_config, default: {}   # service-specific config
      t.boolean :has_own_auth, default: false  # true = service handles auth, WG is defense-in-depth
      t.boolean :enabled, default: true
      t.text :notes
      t.timestamps
    end
  end
end
