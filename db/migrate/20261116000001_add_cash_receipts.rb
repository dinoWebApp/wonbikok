# F5 현금영수증(바로빌 발급대행) — 스키마(PRD 14장 "W3 F5 구현 확정 사항").
# CR-001: mgt_key 유니크 인덱스로 발행 유일성 강제.
# TEN-003: identity_num·guardians.business_number는 Active Record Encryption으로 암호화 저장.
# TEN-002: 주민등록번호는 수집하지 않는다(모델 검증으로 13자리 숫자 거절).
class AddCashReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :cash_receipts do |t|
      t.integer :tenant_id, null: false
      t.integer :invoice_id, null: false
      t.integer :payment_id # F4 수납 연계(W3 후속 — 트리거 출처 기록용)
      t.string :mgt_key, limit: 24, null: false
      t.string :cancel_mgt_key
      t.string :issue_type, default: "income_deduction", null: false
      t.string :state, default: "pending", null: false
      t.integer :barobill_state
      t.string :nts_confirm_num, limit: 9
      t.string :nts_confirm_message
      t.string :identity_num # 암호화(TEN-003) — 휴대폰번호 or 사업자번호
      t.datetime :trade_date
      t.integer :amount, null: false, default: 0
      t.integer :tax, null: false, default: 0
      t.integer :service_charge, null: false, default: 0
      t.string :item_name
      t.datetime :issued_at
      t.datetime :cancelled_at
      t.text :cancel_reason
      t.integer :retry_count, null: false, default: 0
      t.string :last_error
      t.string :issued_by
      t.timestamps
    end

    add_index :cash_receipts, :mgt_key, unique: true
    add_index :cash_receipts, [ :tenant_id, :state ]
    add_index :cash_receipts, :invoice_id
    add_foreign_key :cash_receipts, :tenants
    add_foreign_key :cash_receipts, :invoices

    # RegistCorp(회원사 자동 가입) 필수 수집 항목 — PRD 10.2
    add_column :tenants, :biz_tel, :string
    add_column :tenants, :biz_type, :string # 업태(예: 교육)
    add_column :tenants, :email, :string # 대표자 이메일
    add_column :tenants, :barobill_member_id, :string # 바로빌 회원사 ID(최초 가입 후 불변)
    add_column :tenants, :barobill_joined_at, :datetime

    # 지급증명용(지출증빙) 수취인 식별번호 — 암호화(TEN-003)
    add_column :guardians, :business_number, :string

    # 원생별 발급 유형 선택(F5)
    add_column :students, :cash_receipt_issue_type, :string, null: false, default: "income_deduction"
  end
end
