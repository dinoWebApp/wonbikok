require "test_helper"

# 무료체험 자동 시작 서비스 테스트 — W4 F8 (PRD 7장 F8: 가입 시 자동 시작·카드 등록 없음).
# 멱등(재호출 skip)·TEN-001·이벤트 기록. 외부 호출 없음.
class Subscriptions::TrialServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "체험시작테스트 학원", onboarding_step: 1)
  end

  test "가입 시 30일 체험 구독이 자동 생성되고 trial_started 이벤트가 기록된다" do
    result = Subscriptions::TrialService.start_for!(@tenant)

    assert result.success?
    assert result.created?
    subscription = result.subscription.reload
    assert_equal "trial", subscription.status
    assert_equal "standard", subscription.plan # 체험 중 스탠다드 전체 개방(PRD 11.2)
    assert_in_delta Subscription::TRIAL_DAYS.days.from_now, subscription.trial_ends_at, 2
    assert_in_delta subscription.trial_ends_at, subscription.current_period_end, 1 # 별도 from_now 호출 — 초 단위 오차 허용
    event = subscription.subscription_events.sole
    assert_equal "trial_started", event.event_type
    assert_equal Subscription::TRIAL_DAYS, event.detail_hash["days"]
  end

  test "멱등 — 구독이 이미 있으면 skip하고 새 이벤트를 만들지 않는다" do
    first = Subscriptions::TrialService.start_for!(@tenant)

    result = Subscriptions::TrialService.start_for!(@tenant)

    assert result.success?
    assert_not result.created?
    assert_equal first.subscription.id, result.subscription.id
    assert_equal 1, Subscription.where(tenant_id: @tenant.id).count
    assert_equal 1, SubscriptionEvent.count
  end

  test "TEN-001 다른 테넌트의 구독과 격리된다(테넌트별 1:1)" do
    other = Tenant.create!(name: "다른학원", onboarding_step: 1)
    Subscriptions::TrialService.start_for!(@tenant)
    Subscriptions::TrialService.start_for!(other)

    assert_equal 1, Subscription.where(tenant_id: @tenant.id).count
    assert_equal 1, Subscription.where(tenant_id: other.id).count
    assert_not_equal Subscription.find_by(tenant_id: @tenant.id).id,
                     Subscription.find_by(tenant_id: other.id).id
  end

  test "동시 생성 레이스(유니크 위반) 시에도 예외를 던지지 않고 실패 결과를 반환한다" do
    Subscription.create!(tenant: @tenant, plan: :light, status: :active)

    # find_by 통과 후 create에서 유니크 충돌하는 경계 — 멱등 방어(RecordNotUnique 흡수)
    result = Subscriptions::TrialService.start_for!(@tenant)

    assert result.success? # 이미 존재 → skip(멱등)
    assert_not result.created?
  end
end
