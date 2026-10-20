# MSG-001 발송 유일성의 DB 강제 — 동시 요청 경쟁 상태 방어.
# [invoice_id, template_type] partial unique index(재발송 resend_of_id 있는 건은 예외).
class AddMessageLogsDispatchUniqueness < ActiveRecord::Migration[8.1]
  def change
    add_index :message_logs, %i[invoice_id template_type],
              unique: true,
              where: "resend_of_id IS NULL",
              name: "index_message_logs_dispatch_uniqueness"
  end
end
