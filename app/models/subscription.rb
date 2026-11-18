# 구독 (W4 F8 v1.0 최소형 — PRD 7장 F8, 11장, 14장 W4 확정 블록).
# Tenant 1:1(tenant_id 유니크 — 3-S 통합 마이그레이션에서 생성, 유니크 인덱스 병행).
# 시그니처는 01_plan §2 고정값: plan[light/standard]·status[trial/active/past_due/suspended/cancelled]·
# trial_started_at/trial_ends_at·current_period_start/current_period_end·cancel_scheduled_at.
# 상태 전이는 Subscriptions::*Service 경유만 — 본 모델은 판정 메서드·게이팅 기준을 제공한다.
class Subscription < ApplicationRecord
  # 11.1 플랜 원생 수 상한 — 라이트 30명 / 스탠다드 70명
  PLAN_LIMITS = { light: 30, standard: 70 }.freeze
  # 30일 무료체험(PRD 7장 F8: 가입 시 자동 시작, 카드 등록 없음)
  TRIAL_DAYS = 30

  enum :plan, { light: "light", standard: "standard" }, validate: true
  enum :status, {
    trial: "trial",         # 무료체험(스탠다드 전체 개방 — PRD 11.2)
    active: "active",       # 이용 중(수동 결제 기록·P1 정기결제)
    past_due: "past_due",   # 결제 유예(SUB-003: 30일 데이터 보관 카운트다운 대상)
    suspended: "suspended", # 일시정지(SUB-002: 데이터 유지·조회 허용)
    cancelled: "cancelled"  # 해지
  }, validate: true

  belongs_to :tenant
  has_many :subscription_events, dependent: :destroy

  validates :tenant_id, presence: true, uniqueness: true # TEN-001·1:1 무결성(DB 유니크 인덱스 병행)
  validates :plan, :status, presence: true

  # 체험 종료 임박 대상(기본 D-7 — 3-S recurring.yml D-7 알림 잡의 조회 진입점).
  # trial 상태 & trial_ends_at이 [지금, 지금+within] 구간.
  scope :trial_expiring, ->(within = 7.days) {
    trial.where(trial_ends_at: Time.current..(Time.current + within))
  }

  # 체험 중에는 스탠다드 기능 전체 개방(PRD 11.2) — 상한·기능 게이팅의 유효 플랜
  def effective_plan
    trial? ? :standard : plan.to_sym
  end

  def students_limit
    PLAN_LIMITS.fetch(effective_plan)
  end

  # SUB-001: 재원 원생 수가 플랜 상한에 도달해 신규 등록이 불가한 상태.
  # current_count는 호출자(컨트롤러·서비스)가 Tenant 스코프로 집계해서 전달(TEN-001).
  def students_limit_reached?(current_count)
    current_count.to_i >= students_limit
  end

  # 체험 잔여일(일 단위, 종료 경과 시 음수) — trial_ends_at 미설정이면 nil
  def trial_remain_days(on: Date.current)
    return nil if trial_ends_at.nil?

    (trial_ends_at.to_date - on).to_i
  end

  # 체험 종료 임박 판정(기본 D-7) — trial 상태 & 잔여 0~within일.
  # within은 ActiveSupport::Duration(7.days) 기준 — 일 수로 환산해 비교.
  def trial_expiring?(within: 7.days, on: Date.current)
    return false unless trial?

    remain = trial_remain_days(on: on)
    !remain.nil? && remain >= 0 && remain <= within.to_i / 1.day.to_i
  end

  # 익월 적용 대기 중인 플랜 하향(F8: 하향은 익월부터 — 적용은 PlanChangeService가 수행).
  # 최신 plan_changed 이벤트가 'pending 하향'이면 해당 이벤트, 'applied'이면 nil —
  # 장부는 append-only이므로 최신 이벤트 하나로 대기/적용 여부를 판정한다.
  def pending_downgrade
    events = subscription_events.where(event_type: :plan_changed).order(id: :desc).to_a
    events.each do |event|
      detail = event.detail_hash
      next unless detail["direction"] == "downgrade"

      return detail["status"] == "pending" ? event : nil
    end
    nil
  end
end
