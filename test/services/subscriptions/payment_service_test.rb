require "test_helper"

# 수동 결제 기록 서비스 테스트 — W4 F8 v1.0 최소형 (PRD 7장 F8·11장: 정기결제 도입 전 수동 운영).
# active 전이(체험·유예·정지에서 결제)·기간 1개월 연장·이벤트·거절 케이스. 외부 호출 없음.
class Subscriptions::PaymentServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "수동결제테스트 학원", onboarding_step: 6)
    @subscription = Subscription.create!(
      tenant: @tenant, plan: :light, status: :trial,
      trial_started_at: 27.days.ago, trial_ends_at: 3.days.from_now,
      current_period_start: 27.days.ago, current_period_end: 3.days.from_now
    )
    @service = Subscriptions::PaymentService
  end

  test "체험 중 수동 결제는 active 전이 + 기간 1개월 연장 + manual_payment 이벤트다" do
    result = @service.record_manual!(@subscription, amount: 9_900, method: "transfer",
                                     memo: "계좌 입금", operated_by: "01012345678")

    assert result.success?
    subscription = result.subscription.reload
    assert subscription.active?
    assert_equal "manual_payment", result.event.event_type
    assert_equal 9_900, result.event.amount
    assert_equal "010-****-5678", result.event.operated_by # TEN-003 마스킹
    assert_equal "transfer", result.event.detail_hash["method"]
    assert_equal "trial", result.event.detail_hash["previous_status"]
    # 기간: [period_end, now].max 규약(조기 납부 손실 방지) — 체험 중 결제는 체험 종료일부터 1개월
    assert_in_delta 3.days.from_now, subscription.current_period_start, 5
    assert_in_delta(3.days.from_now + 1.month, subscription.current_period_end, 60)
  end

  test "이용 중(active) 조기 결제는 현재 기간 말에 이어 연장된다(잔여기간 손실 방지)" do
    @subscription.update!(status: :active, current_period_end: 10.days.from_now)

    result = @service.record_manual!(@subscription, amount: 9_900, method: "card")

    assert result.success?
    subscription = result.subscription.reload
    assert_in_delta 10.days.from_now, subscription.current_period_start, 5
    assert_in_delta 10.days.from_now + 1.month, subscription.current_period_end, 60
  end

  test "past_due 상태에서 수동 결제하면 active로 복귀한다(SUB-003 유예 해제)" do
    @subscription.update!(status: :past_due, current_period_end: 20.days.ago)

    result = @service.record_manual!(@subscription, amount: 19_900, method: "transfer")

    assert result.success?
    assert result.subscription.reload.active?
    assert_in_delta 1.month.from_now, result.subscription.current_period_end, 60
  end

  test "suspended 상태에서 수동 결제하면 재활성화된다(SUB-002 정지 해제)" do
    @subscription.update!(status: :suspended)

    result = @service.record_manual!(@subscription, amount: 9_900, method: "cash")

    assert result.success?
    assert result.subscription.reload.active?
  end

  test "cancelled 구독의 수동 결제는 거절된다" do
    @subscription.update!(status: :cancelled)

    result = @service.record_manual!(@subscription, amount: 9_900, method: "transfer")

    assert_not result.success?
    assert result.subscription.reload.cancelled?
    assert result.subscription.errors.of_kind?(:status, :manual_payment_not_accepted)
    assert_empty @subscription.subscription_events
  end

  test "금액 0·음수·수단 공백은 거절되고 이벤트가 남지 않는다" do
    result = @service.record_manual!(@subscription, amount: 0, method: "transfer")
    assert_not result.success?
    assert @subscription.errors.of_kind?(:amount, :payment_amount_invalid)

    result = @service.record_manual!(@subscription, amount: -1, method: "transfer")
    assert_not result.success?

    result = @service.record_manual!(@subscription, amount: 9_900, method: "  ")
    assert_not result.success?
    assert @subscription.errors.of_kind?(:base, :payment_method_blank)

    assert_empty @subscription.subscription_events
    assert @subscription.reload.trial? # 상태 불변
  end

  test "결제 갱신 시 대기 중 플랜 하향이 함께 확정된다(PaymentService ↔ PlanChangeService)" do
    @subscription.update!(status: :active, plan: :standard)
    Subscriptions::PlanChangeService.change!(@subscription, plan: :light,
                                             operated_by: "admin", reason: "축소")
    assert_equal "standard", @subscription.reload.plan # 대기 중 — 아직 유지

    result = @service.record_manual!(@subscription, amount: 9_900, method: "transfer")

    assert result.success?
    assert_equal "light", result.subscription.reload.plan # 갱신 = 익월 경계 적용
    assert_nil result.subscription.pending_downgrade # 대기 소비 완료
    assert result.subscription.subscription_events.manual_payment.exists?
  end
end
