class CreateInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :invoices do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :student, null: false, foreign_key: true
      t.string :target_month, null: false # "YYYY-MM"
      t.string :student_name_snapshot, null: false # TEN-004
      t.integer :base_amount, null: false
      t.integer :adjustment_amount, default: 0, null: false
      t.string :adjustment_note
      t.date :due_on
      t.string :status, default: "DRAFT", null: false
      t.datetime :sent_at
      t.datetime :cancelled_at
      t.string :cancel_reason
      # INV-002: 확정(READY) 이후 금액 수정 시 변경 사유 이력(JSON 배열)
      t.text :change_history

      t.timestamps
    end

    # INV-001: 같은 원생 × 같은 월 중복 청구 금지(DB 레벨 강제)
    add_index :invoices, %i[student_id target_month], unique: true,
                                                      name: "index_invoices_on_student_and_target_month"
    add_index :invoices, %i[tenant_id target_month status]
  end
end
