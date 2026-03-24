class CreateCronMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :cron_messages do |t|
      t.string :channel, null: false          # room slug (e.g. "infra")
      t.string :schedule, null: false         # cron expression (e.g. "0 8 * * *")
      t.text :body, null: false               # message body (may include @mentions)
      t.boolean :enabled, default: true
      t.datetime :last_fired_at
      t.datetime :next_fire_at
      t.text :notes
      t.timestamps
    end
  end
end
