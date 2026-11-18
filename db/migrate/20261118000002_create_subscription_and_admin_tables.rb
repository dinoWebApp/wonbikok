# W4 병렬 배치 통합 마이그레이션 (F7·F8·관리자 A0~A3 — 01_plan.md §2 Subscription 시그니처 고정값).
# - subscriptions: Tenant 1:1(tenant_id 유니크 — SUB-001 게이팅·체험/플랜/상태 전이 기준).
# - subscription_events: 구독 이벤트 장부(A2 타임라인·A3 결제 이력 동일 테이블 서빙) —
#   append-only(created_at만, updated_at 없음 — 모델 컬럼 부재 시 자동 skip).
# - admin_users: 관리자 A0(이메일+비밀번호+TOTP 시크릿·5회 잠금).
# - audit_logs: ADM-001 감사 로그(영구 보존 — 조치 사유·대상·detail).
class CreateSubscriptionAndAdminTables < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions do |t|
      t.references :tenant, null: false, foreign_key: true, index: { unique: true } # SUB-001·TEN-001 1:1
      t.string :plan, null: false, default: "standard" # light/standard
      t.string :status, null: false, default: "trial"  # trial/active/past_due/suspended/cancelled
      t.datetime :trial_started_at
      t.datetime :trial_ends_at
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :cancel_scheduled_at # v1.0: 컬럼·표시만(설정 경로는 후속)
      t.timestamps
    end

    create_table :subscription_events do |t|
      t.references :subscription, null: false, foreign_key: true
      t.string :event_type, null: false
      t.integer :amount # 결제 계열만 셋팅(원 단위)
      t.text :detail    # JSON 문자열 장부(구조적 상세 — f8 규약)
      t.string :operated_by # 처리자 — 마스킹 저장(SubscriptionEvent#operated_by=, TEN-003)
      t.datetime :created_at, null: false # append-only 장부 — created_at만
    end
    add_index :subscription_events, [ :subscription_id, :event_type ]

    create_table :admin_users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :otp_secret            # 사전 공유 TOTP 시크릿(평문 — 화면·로그 노출 금지, ADM-002)
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_at
      t.timestamps
    end
    add_index :admin_users, :email, unique: true

    create_table :audit_logs do |t|
      t.references :admin_user, null: true, foreign_key: true # 로그인 실패 등 계정 미확인 기록 허용
      t.string :action, null: false
      t.string :target_type
      t.integer :target_id
      t.text :reason
      t.json :detail                      # SQLite json(Hash 저장 — days·branch·amount 등)
      t.timestamps
    end
    add_index :audit_logs, [ :target_type, :target_id ]
    add_index :audit_logs, [ :action, :created_at ]
  end
end
