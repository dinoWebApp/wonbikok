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

ActiveRecord::Schema[8.1].define(version: 2026_10_20_000010) do
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

  create_table "invoices", force: :cascade do |t|
    t.integer "tenant_id", null: false
    t.integer "student_id", null: false
    t.string "target_month", null: false
    t.string "student_name_snapshot", null: false
    t.integer "base_amount", null: false
    t.integer "adjustment_amount", default: 0, null: false
    t.string "adjustment_note"
    t.date "due_on"
    t.string "status", default: "DRAFT", null: false
    t.datetime "sent_at"
    t.datetime "cancelled_at"
    t.string "cancel_reason"
    t.text "change_history"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["student_id", "target_month"], name: "index_invoices_on_student_and_target_month", unique: true
    t.index ["student_id"], name: "index_invoices_on_student_id"
    t.index ["tenant_id", "target_month", "status"], name: "index_invoices_on_tenant_id_and_target_month_and_status"
    t.index ["tenant_id"], name: "index_invoices_on_tenant_id"
  end

  create_table "message_logs", force: :cascade do |t|
    t.integer "tenant_id", null: false
    t.integer "invoice_id", null: false
    t.integer "student_id", null: false
    t.string "channel", default: "alimtalk", null: false
    t.string "template_type", null: false
    t.string "status", default: "QUEUED", null: false
    t.string "provider_message_id"
    t.string "error_code"
    t.text "error_message"
    t.datetime "sent_at"
    t.bigint "resend_of_id"
    t.string "job_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id", "template_type"], name: "index_message_logs_dispatch_uniqueness", unique: true, where: "resend_of_id IS NULL"
    t.index ["invoice_id", "template_type"], name: "index_message_logs_on_invoice_id_and_template_type"
    t.index ["invoice_id"], name: "index_message_logs_on_invoice_id"
    t.index ["resend_of_id"], name: "index_message_logs_on_resend_of_id"
    t.index ["student_id"], name: "index_message_logs_on_student_id"
    t.index ["tenant_id"], name: "index_message_logs_on_tenant_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
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
    t.boolean "excluded_from_reminders", default: false, null: false
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
    t.string "remind_tone", default: "standard", null: false
    t.boolean "remind_d3_enabled", default: true, null: false
    t.boolean "remind_d7_enabled", default: true, null: false
    t.boolean "remind_month_end_enabled", default: true, null: false
    t.integer "remind_send_hour", default: 9, null: false
    t.text "remind_custom_text_d3"
    t.text "remind_custom_text_d7"
    t.text "remind_custom_text_month_end"
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
  add_foreign_key "invoices", "students"
  add_foreign_key "invoices", "tenants"
  add_foreign_key "message_logs", "invoices"
  add_foreign_key "message_logs", "students"
  add_foreign_key "message_logs", "tenants"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "students", "tenants"
  add_foreign_key "users", "tenants"
end
