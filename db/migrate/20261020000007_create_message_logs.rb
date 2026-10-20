class CreateMessageLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :message_logs do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :student, null: false, foreign_key: true
      t.string :channel, default: "alimtalk", null: false # alimtalk / sms
      t.string :template_type, null: false # invoice_notice / reminder_d3 / reminder_d7 / reminder_month_end
      t.string :status, default: "QUEUED", null: false # QUEUED/SENDING/SENT/FAILED/FALLBACK_SENT/SIMULATED (9.3)
      t.string :provider_message_id
      t.string :error_code
      t.text :error_message
      t.datetime :sent_at
      t.bigint :resend_of_id # 재발송 원본 MessageLog 연결(MSG-001 예외 이력)
      # MSG-007: 예약발송 취소를 위한 ActiveJob 식별자(예약 대기열 관리)
      t.string :job_id

      t.timestamps
    end

    add_index :message_logs, %i[invoice_id template_type]
    add_index :message_logs, :resend_of_id
  end
end
