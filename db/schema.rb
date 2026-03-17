# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_17_000004) do
  create_table "agents", force: :cascade do |t|
    t.integer "identity_id", null: false
    t.integer "room_id", null: false
    t.string "instance_name", null: false
    t.string "wg_address"
    t.string "wg_pubkey"
    t.string "state", default: "resolving"
    t.datetime "last_message_at"
    t.float "context_usage", default: 0.0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identity_id"], name: "index_agents_on_identity_id"
    t.index ["instance_name"], name: "index_agents_on_instance_name", unique: true
    t.index ["room_id"], name: "index_agents_on_room_id"
  end

  create_table "identities", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "singleton", default: false
    t.text "system_prompt"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_identities_on_name", unique: true
  end

  create_table "listeners", force: :cascade do |t|
    t.integer "identity_id", null: false
    t.string "channel_slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identity_id", "channel_slug"], name: "index_listeners_on_identity_id_and_channel_slug", unique: true
    t.index ["identity_id"], name: "index_listeners_on_identity_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.string "matrix_room_id", null: false
    t.string "name"
    t.string "slug"
    t.string "spawn_policy", default: "on_mention"
    t.integer "timeout_seconds", default: 600
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["matrix_room_id"], name: "index_rooms_on_matrix_room_id", unique: true
    t.index ["slug"], name: "index_rooms_on_slug"
  end

  add_foreign_key "agents", "identities"
  add_foreign_key "agents", "rooms"
  add_foreign_key "listeners", "identities"
end
