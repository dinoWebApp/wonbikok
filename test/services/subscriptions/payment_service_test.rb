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

  # ==================================================================
  # F10: 추천 시스템 확장 — 첫 결제 20% 할인(REF-002)·수수료 원장 축적(REF-003/004)
  # ==================================================================
  test "F10 피추천 테넌트 첫 결제는 20% 할인 후 금액으로 기록되고 ledger가 생성된다" do
    rep = SalesRep.create!(name: "F10직원", email: "pay-f10@example.com",
                           password: "password123", role: "sales")
    @tenant.update!(referred_by_sales_rep: rep)

    result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert result.success?
    event = result.event
    assert_equal 8_000, event.amount # 징수 = 할인 후
    detail = event.detail_hash
    assert_equal 10_000, detail["original_amount"]
    assert detail["discount_applied"] == true
    assert_equal 2_000, detail["discount_amount"]
    # REF-003: 할인 후 실제 징수액 기준 ledger
    ledger = CommissionLedger.sole
    assert_equal @tenant.id, ledger.tenant_id
    assert_equal rep.id, ledger.sales_rep_id
    assert_equal 8_000, ledger.base_amount
    assert_equal 1_600, ledger.amount
    assert_equal event.id, ledger.source_subscription_event_id
    assert_not_nil @tenant.reload.first_payment_discounted_at
  end

  test "F10 두 번째 결제는 정상가이며 ledger도 정상가 기준이다(재결제 미적용)" do
    rep = SalesRep.create!(name: "F10직원2", email: "pay-f10b@example.com",
                           password: "password123", role: "sales")
    @tenant.update!(referred_by_sales_rep: rep)
    @service.record_manual!(@subscription, amount: 10_000, method: "transfer")
    first_period_end = @subscription.reload.current_period_end

    result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert result.success?
    assert_equal 10_000, result.event.amount # 정상가
    assert_equal false, result.event.detail_hash["discount_applied"]
    assert_equal 2, CommissionLedger.count
    assert_equal 10_000, CommissionLedger.order(:id).last.base_amount
    assert_equal first_period_end, result.subscription.reload.current_period_start
  end

  test "F10 비추천 테넌트는 할인·ledger 없이 기존 동작을 유지한다(회귀 방어)" do
    result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert result.success?
    assert_equal 10_000, result.event.amount
    assert_equal false, result.event.detail_hash["discount_applied"]
    assert_equal 0, CommissionLedger.count
  end

  test "F10 수수료 축적 실패는 결제 성공을 롤백하지 않는다(PAY-004 준용)" do
    rep = SalesRep.create!(name: "F10직원3", email: "pay-f10c@example.com",
                           password: "password123", role: "sales")
    @tenant.update!(referred_by_sales_rep: rep)
    original = Referral::CommissionService.method(:accrue_on_payment!)
    Referral::CommissionService.define_singleton_method(:accrue_on_payment!) do |*|
      raise StandardError, "수수료 계산 장애"
    end

    result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert result.success? # 결제 유지
    assert result.subscription.reload.active?
    assert_equal 8_000, result.event.amount # 할인은 유지
    assert_equal 0, CommissionLedger.count # ledger만 미생성
  ensure
    Referral::CommissionService.define_singleton_method(:accrue_on_payment!, original)
  end

  test "F10 할인 적용 실패 시 정상가로 결제를 진행한다" do
    rep = SalesRep.create!(name: "F10직원4", email: "pay-f10d@example.com",
                           password: "password123", role: "sales")
    @tenant.update!(referred_by_sales_rep: rep)
    original = Referral::DiscountService.method(:apply_first_payment!)
    Referral::DiscountService.define_singleton_method(:apply_first_payment!) do |*|
      raise StandardError, "할인 판정 장애"
    end

    result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert result.success?
    assert_equal 10_000, result.event.amount # 정상가 폴백
    assert_equal 10_000, CommissionLedger.sole.base_amount
  ensure
    Referral::DiscountService.define_singleton_method(:apply_first_payment!, original)
  end

  # 1차 리뷰 Tester 제안(05_review): claim은 결제 트랜잭션 내부 원자 갱신이므로 결제 실패
  # 롤백 시 first_payment_discounted_at도 원복되어야 하고, 재시도 결제에 할인이 다시 적용된다.
  test "F10 결제 트랜잭션 롤백 시 할인 claim이 원복되어 재시도 결제에 할인이 재적용된다" do
    rep = SalesRep.create!(name: "F10직원5", email: "pay-f10e@example.com",
                           password: "password123", role: "sales")
    @tenant.update!(referred_by_sales_rep: rep)
    # claim(할인 적용) 이후 기간 갱신 단계에서 1회 한정 실패 유도 — 트랜잭션 롤백 경로
    original = @subscription.method(:update!)
    calls = 0
    @subscription.define_singleton_method(:update!) do |*args, **kwargs, &block|
      calls += 1
      if calls == 1 # RecordInvalid는 record 기반 생성자 — 검증 실패와 동일 형태로 raise
        errors.add(:base, "기간 갱신 장애 시나리오")
        raise ActiveRecord::RecordInvalid.new(self)
      end
      original.call(*args, **kwargs, &block)
    end

    first = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert_not first.success? # 갱신 실패 → 트랜잭션 롤백으로 결제도 실패
    assert_nil @tenant.reload.first_payment_discounted_at # claim이 같은 트랜잭션에서 원복됨
    assert @subscription.reload.trial?
    assert_empty @subscription.subscription_events
    assert_equal 0, CommissionLedger.count

    # 재시도 결제 — 원복된 claim 덕분에 첫 결제로 인식되어 할인이 다시 적용된다
    retry_result = @service.record_manual!(@subscription, amount: 10_000, method: "transfer")

    assert retry_result.success?
    assert_equal 8_000, retry_result.event.amount
    assert retry_result.event.detail_hash["discount_applied"] == true
    assert_not_nil @tenant.reload.first_payment_discounted_at
    assert_equal 1, CommissionLedger.count # 실패 건의 잔존(이벤트·ledger) 없음
  ensure
    @subscription.singleton_class.send(:remove_method, :update!) if calls&.positive?
  end
end
