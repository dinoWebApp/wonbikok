# 구독 이벤트 장부 (W4 F8 — 01_plan §2: A2 타임라인과 A3 결제 이력을 동일 테이블로 서빙).
# 타입: trial_started/manual_payment/payment_failed/retry/past_due/suspended/plan_changed/refund.
# 생성은 Subscriptions::*Service(도메인 서비스)만 허용 — 컨트롤러·뷰에서 직접 생성 금지.
# append-only 장부(수정·삭제 없음) — updated_at 없이 created_at만(3-S 마이그레이션 스펙).
# 컬럼은 3-S 통합 마이그레이션에서 생성(subscription_id·event_type·amount·detail·operated_by·created_at).
class SubscriptionEvent < ApplicationRecord
  enum :event_type, {
    trial_started: "trial_started",
    trial_extended: "trial_extended", # 체험 연장(관리자 A2 — 1회 최대 30일·누적 60일 상한)
    manual_payment: "manual_payment",
    payment_failed: "payment_failed",
    retry: "retry", # 재시도 예약·실행 기록(SUB-002 — D+1/D+3/D+5, 상한 3회)
    past_due: "past_due",
    suspended: "suspended",
    plan_changed: "plan_changed",
    refund: "refund" # A3 환불(후속 — 본 배치는 기록 타입만 정의)
  }, validate: true

  belongs_to :subscription

  validates :event_type, presence: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # detail은 JSON 문자열(구조적 장부). 파싱 실패는 빈 해시 — 장부 열람이 절대 깨지지 않게.
  def detail_hash
    JSON.parse(detail.to_s)
  rescue JSON::ParserError
    {}
  end

  # TEN-003: 처리자 휴대폰번호 원문 저장 금지 — Payment#confirmed_by=와 동일 마스킹 패턴
  def operated_by=(value)
    raw = value.to_s
    masked = raw.match?(/\A01[016789]\d{7,8}\z/) ? "#{raw[0, 3]}-****-#{raw[-4, 4]}" : value
    super(masked)
  end
end
