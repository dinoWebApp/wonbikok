require "test_helper"

# 결제 실패 재시도 프레임 서비스 테스트 — W4 F8 (SUB-002·003·MSG-003).
# D+1/D+3/D+5 스케줄 데이터·3회 실패 past_due 전이·suspend!(SUB-002)·
# SUB-003 보관 만료 카운트다운 계산. 외부 호출 없음(실 재시도 청구는 P1).
class Subscriptions::RetryPolicyServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "재시도프레임테스트 학원", onboarding_step: 6)
    @subscription = Subscription.create!(
      tenant: @tenant, plan: :light, status: :active,
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    @service = Subscriptions::RetryPolicyService
  end

  test "1회 실패 시 payment_failed + retry(D+1) 이벤트가 기록되고 상태는 유지된다" do
    result = @service.record_failure!(@subscription, amount: 9_900,
                                      failed_at: Time.zone.parse("2026-11-18 10:00"),
                                      operated_by: "system")

    assert result.success?
    assert_not result.status_changed?
    assert @subscription.reload.active?
    failed = @subscription.subscription_events.payment_failed.sole
    assert_equal 9_900, failed.amount
    assert_equal 1, failed.detail_hash["attempt"]
    assert_equal "2026-11-19", failed.detail_hash["next_retry_on"] # D+1
    assert_not failed.detail_hash["retries_exhausted"]
    retry_event = @subscription.subscription_events.retry.sole
    assert_equal 2, retry_event.detail_hash["attempt"]
    assert_equal "2026-11-19", retry_event.detail_hash["scheduled_on"]
  end

  test "재시도 스케줄은 D+1/D+3/D+5다(PRD 7장 F8)" do
    schedule = @service.retry_schedule(Time.zone.parse("2026-11-18 10:00"))

    assert_equal [ Date.new(2026, 11, 19), Date.new(2026, 11, 21), Date.new(2026, 11, 23) ], schedule
  end

  test "2회 실패까지는 active 유지, 3회 실패 시 past_due 전이 + 보관 만료일 기록이다(SUB-002)" do
    failed_at = Time.zone.parse("2026-11-18 10:00")
    @service.record_failure!(@subscription, failed_at: failed_at)
    @service.record_failure!(@subscription, failed_at: failed_at + 1.day)

    travel_to Time.zone.parse("2026-11-21 10:00") do
      result = @service.record_failure!(@subscription, failed_at: Time.current)

      assert result.status_changed?
    end

    subscription = @subscription.reload
    assert subscription.past_due?
    assert_equal 3, subscription.subscription_events.payment_failed.count
    last_failed = subscription.subscription_events.payment_failed.order(:id).last
    assert last_failed.detail_hash["retries_exhausted"]
    assert_nil last_failed.detail_hash["next_retry_on"] # 재시도 소진 — 무한 반복 금지(MSG-003)
    past_due_event = subscription.subscription_events.past_due.sole
    assert_equal 3, past_due_event.detail_hash["failures"]
    assert_equal Date.new(2026, 12, 21), Date.iso8601(past_due_event.detail_hash["retention_deadline"])
  end

  test "4회차 이상 실패는 past_due 중복 전이 없이 기록만 추가된다(MSG-003 무한 반복 금지)" do
    3.times { @service.record_failure!(@subscription) }
    result = @service.record_failure!(@subscription)

    assert result.success?
    assert_not result.status_changed?
    assert @subscription.reload.past_due?
    assert_equal 1, @subscription.subscription_events.past_due.count
    assert_equal 4, @subscription.subscription_events.payment_failed.count
    assert_equal 2, @subscription.subscription_events.retry.count # 실패 1·2회차에만 예약(3회 = past_due 전이)
  end

  test "수동 결제 성공 후 실패 카운터는 리셋된다(재시도 프레임 재가동)" do
    2.times { @service.record_failure!(@subscription) }
    assert_equal 2, @service.failure_count(@subscription.reload)

    Subscriptions::PaymentService.record_manual!(@subscription, amount: 9_900, method: "transfer")

    assert_equal 0, @service.failure_count(@subscription.reload)
  end

  test "체험·정지·해지 상태의 실패 기록은 거절된다" do
    @subscription.update!(status: :trial)
    assert_not @service.record_failure!(@subscription).success?

    @subscription.update!(status: :suspended)
    assert_not @service.record_failure!(@subscription).success?

    @subscription.update!(status: :cancelled)
    assert_not @service.record_failure!(@subscription).success?
    assert_equal 0, @subscription.subscription_events.payment_failed.count
  end

  test "expire_due_trials!는 만료 체험을 past_due로 전이하고 결제된 구독은 건드리지 않는다(SUB-003 진입)" do
    expired = Subscription.create!(
      tenant: Tenant.create!(name: "만료체험학원"), plan: :light, status: :trial,
      trial_started_at: 40.days.ago, trial_ends_at: 3.days.ago,
      current_period_start: 40.days.ago, current_period_end: 3.days.ago
    )
    paid = Subscription.create!(
      tenant: Tenant.create!(name: "결제체험학원"), plan: :light, status: :trial,
      trial_started_at: 40.days.ago, trial_ends_at: 3.days.ago,
      current_period_start: 40.days.ago, current_period_end: 3.days.ago
    )
    Subscriptions::PaymentService.record_manual!(paid, amount: 9_900, method: "transfer") # active 전이

    transitioned = @service.expire_due_trials!

    assert_includes transitioned, expired
    assert expired.reload.past_due?
    past_due_event = expired.subscription_events.past_due.sole
    assert_equal 0, past_due_event.detail_hash["failures"]
    assert_equal "trial_expired", past_due_event.detail_hash["reason"]
    assert_not_includes transitioned, paid
    assert paid.reload.active?
    assert_not_nil @service.data_retention_deadline(expired.reload) # SUB-003 카운트다운 시작
  end

  test "suspend!는 past_due에서만 허용되고 suspended 전이·이벤트를 남긴다(SUB-002)" do    assert_not @service.suspend!(@subscription, reason: "무단 미결제").success? # active → 거절
    3.times { @service.record_failure!(@subscription) }
    result = @service.suspend!(@subscription, reason: "무단 미결제", operated_by: "admin@wonbikok.kr")

    assert result.success?
    assert result.status_changed?
    assert @subscription.reload.suspended?
    suspended = @subscription.subscription_events.suspended.sole
    assert_equal "무단 미결제", suspended.detail_hash["reason"]

    assert_not @service.suspend!(@subscription).success? # 재정지 거절
    assert_equal 1, @subscription.subscription_events.suspended.count
  end

  test "SUB-003 데이터 보관 만료일은 past_due 시점 + 30일 카운트다운이다" do
    assert_nil @service.data_retention_deadline(@subscription) # past_due 이력 없음

    travel_to Time.zone.parse("2026-11-18 10:00") do
      3.times { @service.record_failure!(@subscription) }
    end

    deadline = @service.data_retention_deadline(@subscription.reload)
    assert_equal Date.new(2026, 12, 18), deadline
    assert_equal 30, @service.remaining_retention_days(@subscription, on: Date.new(2026, 11, 18))
    assert_equal 1, @service.remaining_retention_days(@subscription, on: Date.new(2026, 12, 17))
    assert_equal 0, @service.remaining_retention_days(@subscription, on: Date.new(2026, 12, 18))
    assert_equal(-1, @service.remaining_retention_days(@subscription, on: Date.new(2026, 12, 19)))
  end
end
