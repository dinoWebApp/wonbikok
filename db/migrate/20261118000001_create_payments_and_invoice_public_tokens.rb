# W3 F4/F9 통합 마이그레이션 (PRD 14장 "W3 F4/F9 구현 확정 사항(2026-11-18)").
# - payments 테이블: 수납 이력(PAY-001~004 — 삭제 아닌 취소 이력 관리).
# - invoices 토큰 컬럼: 학부모 청구 링크(LNK-001~003 — 예측 불가 토큰·발급/폐기 시각).
class CreatePaymentsAndInvoicePublicTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :payments do |t|
      t.references :invoice, null: false, foreign_key: true
      t.references :tenant, null: false, foreign_key: true
      t.integer :amount, null: false # 원 단위
      t.date :paid_on, null: false
      t.string :method, null: false # transfer/card/cash/other
      t.string :memo
      t.string :status, null: false, default: "active" # active/cancelled (PAY-002: 취소 이력)
      t.string :cancel_reason
      t.datetime :cancelled_at
      t.string :cancelled_by # 처리자 — 마스킹 저장(Payment#cancelled_by=, TEN-003)
      t.string :confirmed_by # 처리자 — 마스킹 저장(Payment#confirmed_by=, TEN-003)
      t.datetime :confirmed_at
      t.timestamps
    end

    # active 합계 조회·PAY-001(완납 재처리 차단) 판정 지원
    # (tenant_id 인덱스는 t.references가 자동 생성)
    add_index :payments, [ :invoice_id, :status ]
    # PAY-001 데이터 무결성 보강 — 금액은 양수만(SQLite CHECK, 모델 검증의 DB 계층 이중 방어)
    add_check_constraint :payments, "amount > 0", name: "chk_payments_amount_positive"

    # F9 학부모 청구 링크 토큰(LNK-001: SecureRandom urlsafe 32자 — 예측 불가·개인정보 미포함)
    add_column :invoices, :public_token, :string
    add_column :invoices, :public_token_issued_at, :datetime
    add_column :invoices, :public_token_revoked_at, :datetime
    # 전역 유니크 — 미발급(NULL) 다중 허용의 부분 유니크 인덱스(LNK-001·TEN-001)
    add_index :invoices, :public_token, unique: true, where: "public_token IS NOT NULL",
              name: "index_invoices_on_public_token"
  end
end
