class CreateOfficeActions < ActiveRecord::Migration[8.1]
  def change
    create_table :office_actions, id: :string do |t|
      t.string :handle, null: false
      t.string :action, null: false          # wake | freeze | spawn | rescue | destroy
      t.string :reason
      t.string :state, null: false, default: "pending"
      t.text   :detail                        # the executor's own words
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :office_actions, [:handle, :created_at]
    add_index :office_actions, :state
  end
end
