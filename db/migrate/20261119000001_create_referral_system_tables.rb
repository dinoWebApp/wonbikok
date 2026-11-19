# F10 영업 직원·오피서 추천 시스템 (PRD 7장 F10·14장 F10 확정 블록·22장 REF-001~007).
# 단일 통합 마이그레이션 — 4 신규 테이블 + tenants 확장.
#
# - sales_reps: 역할 체계(role sales/officer) 단일 테이블. commission_rate·commission_cap_months는
#   DB 기본 NULL — 모델 role 기본값(sales 0.20/12개월 · officer 0.15/무기한) 경유(REF-003).
#   failed_attempts·locked_at은 영업 대시보드 로그인 5회 실패 잠금(AdminUser와 동일 규약).
# - referral_codes: 주간 로테이션(REF-001) — 만료·교체 코드는 삭제 금지, replaced_at으로 이력 보존.
# - signup_verifications: 가입 휴대폰 인증(REF-006) — 코드는 평문 저장 금지(code_digest bcrypt).
# - commission_ledgers: 수수료 원장(REF-004 결제 시점 스냅샷) — pending/paid 월 후불 정산.
# - tenants: 추천 매핑 스냅샷(TEN-004 준용 — 이후 코드 로테이션 영향 없음) + 첫 결제 할인 멱등 표시(REF-002).
class CreateReferralSystemTables < ActiveRecord::Migration[8.1]
  def change
    create_table :sales_reps do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :role, null: false, default: "sales"   # sales/officer
      t.string :title                                  # 표시용 자유 텍스트 직함("영업 이사" 등)
      t.string :status, null: false, default: "active" # active/suspended
      t.decimal :commission_rate, precision: 4, scale: 4    # nil이면 role 기본(모델)
      t.integer :commission_cap_months                       # nil이면 role 기본(officer=무기한)
      t.text :suspended_reason                               # 정지 사유(ADM-001 — 정지 시 필수)
      t.integer :failed_attempts, null: false, default: 0    # 로그인 실패 카운트(5회 잠금)
      t.datetime :locked_at
      t.timestamps
    end
    add_index :sales_reps, :email, unique: true

    create_table :referral_codes do |t|
      t.references :sales_rep, null: false, foreign_key: true
      t.string :code, null: false
      t.datetime :expires_at, null: false # 7일 유효(REF-001)
      t.datetime :replaced_at             # 로테이션·정지 무효화 이력 보존 — 만료 코드 삭제 금지
      t.timestamps
    end
    add_index :referral_codes, :code, unique: true
    add_index :referral_codes, [ :sales_rep_id, :replaced_at ]

    create_table :signup_verifications do |t|
      t.string :phone_number, null: false # 정규화 숫자만 — 모델에서 deterministic 암호화(TEN-003)
      t.string :code_digest, null: false  # bcrypt 해시 — 평문 저장 금지(REF-006)
      t.datetime :expires_at, null: false # 5분 유효
      t.integer :attempts, null: false, default: 0 # 시도 5회 제한
      t.datetime :verified_at
      t.datetime :consumed_at             # 가입 소비 표시 — 재사용 방지
      t.timestamps
    end
    add_index :signup_verifications, :phone_number

    create_table :commission_ledgers do |t|
      t.references :sales_rep, null: false, foreign_key: true
      t.references :tenant, null: false, foreign_key: true
      t.string :month, null: false            # YYYY-MM (결제 시점 기준)
      t.integer :base_amount, null: false     # 실제 징수액(할인 후·REF-003)
      t.decimal :rate, precision: 4, scale: 4, null: false # 결제 시점 요율 스냅샷(REF-004)
      t.integer :amount, null: false          # 수수료액 = base_amount × rate
      t.string :status, null: false, default: "pending" # pending/paid
      t.datetime :paid_at
      t.integer :source_subscription_event_id # 발생 근거 manual_payment 이벤트(append-only 장부 참조)
      t.timestamps
    end
    add_index :commission_ledgers, [ :sales_rep_id, :month ]
    add_index :commission_ledgers, :source_subscription_event_id

    add_column :tenants, :referred_by_sales_rep_id, :integer
    add_column :tenants, :referral_code_snapshot, :string # 가입 시점 코드 스냅샷(TEN-004 준용)
    add_column :tenants, :first_payment_discounted_at, :datetime # REF-002 멱등 표시
    add_index :tenants, :referred_by_sales_rep_id
  end
end
