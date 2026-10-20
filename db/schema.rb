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

ActiveRecord::Schema[8.1].define(version: 2026_10_20_000005) do
  create_table "guardians", force: :cascade do |t|
    t.integer "student_id", null: false
    t.string "name", null: false
    t.string "phone_number", null: false
    t.string "phone_last4", null: false
    t.boolean "is_primary", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["phone_last4"], name: "index_guardians_on_phone_last4"
    t.index ["student_id"], name: "index_guardians_on_student_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "students", force: :cascade do |t|
    t.integer "tenant_id", null: false
    t.string "name", null: false
    t.string "grade"
    t.integer "monthly_fee", default: 0, null: false
    t.integer "payment_day", default: 25, null: false
    t.string "payment_type", default: "계좌이체", null: false
    t.text "memo"
    t.string "status", default: "active", null: false
    t.date "started_on"
    t.date "ended_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "status"], name: "index_students_on_tenant_id_and_status"
    t.index ["tenant_id"], name: "index_students_on_tenant_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.string "name", null: false
    t.string "business_number"
    t.string "business_type"
    t.string "owner_name"
    t.string "address"
    t.string "bank_name"
    t.string "bank_account"
    t.string "account_holder"
    t.boolean "practice", default: false, null: false
    t.integer "onboarding_step", default: 1, null: false
    t.string "cash_receipt_link_status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.integer "tenant_id", null: false
    t.string "phone_number", null: false
    t.string "password_digest", null: false
    t.string "role", default: "owner", null: false
    t.datetime "last_login_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["phone_number"], name: "index_users_on_phone_number", unique: true
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "guardians", "students"
  add_foreign_key "sessions", "users"
  add_foreign_key "students", "tenants"
  add_foreign_key "users", "tenants"
end
