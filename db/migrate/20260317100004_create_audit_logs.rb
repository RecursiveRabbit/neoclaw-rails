class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.string :event, null: false            # SPAWN, FREEZE, CRASH, PROVISION, etc
      t.string :instance_name
      t.string :identity
      t.text :detail
      t.datetime :created_at, null: false
    end

    add_index :audit_logs, :created_at
    add_index :audit_logs, :event
  end
end
