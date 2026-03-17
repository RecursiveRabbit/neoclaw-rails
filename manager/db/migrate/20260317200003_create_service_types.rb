class CreateServiceTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :service_types do |t|
      t.string :name, null: false, index: { unique: true }
      t.string :wg_interface              # "wg-git"
      t.string :wg_ip                     # "10.0.0.3"
      t.string :wg_public_key
      t.string :wg_endpoint              # "host:51823"
      t.integer :wg_listen_port
      t.string :provision_type            # "forgejo", "ssh_key", "token", "none"
      t.json :provision_config, default: {}
      t.boolean :has_own_auth, default: false
      t.boolean :enabled, default: true
      t.text :notes
      t.timestamps
    end
  end
end
