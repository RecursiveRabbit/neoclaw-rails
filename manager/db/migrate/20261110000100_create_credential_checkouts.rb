class CreateCredentialCheckouts < ActiveRecord::Migration[8.1]
  def change
    create_table :credential_checkouts, id: false do |t|
      t.string :id, primary_key: true, null: false
      # What was issued. A scope is a class of credential, not a secret.
      t.string :scope, null: false
      # Which agent instance the credential belongs to (the pod's name).
      t.string :instance_name, null: false
      # Which launch minted it: "<boot_id>:<instance_name>". The ledger's join
      # key to a pod, and how an orphan is matched without a pod registry.
      t.string :launch_ref, null: false
      # Opaque locator a revoker can act on: "forgejo:user:<name>",
      # "file:<path>", "valley:token:<name>", "generic:<endpoint>".
      # NEVER a secret value.
      t.string :revoke_handle, null: false
      # true when no revocation endpoint exists — the row stays open and is
      # reported, not silently marked clean.
      t.boolean :unrevocable, null: false, default: false
      t.datetime :issued_at, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.string :revoked_reason
      t.string :note
      t.timestamps
    end

    add_index :credential_checkouts, [:instance_name, :scope]
    add_index :credential_checkouts, :revoked_at
    add_index :credential_checkouts, :launch_ref
  end
end
