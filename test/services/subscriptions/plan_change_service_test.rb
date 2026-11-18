require "test_helper"

# 플랜 변경 서비스 테스트 — W4 F8 (PRD 7장 F8: 상향 즉시·기간 유지, 하향 익월.
# ADM-001 정신: 사유 없는 변경 거절).
class Subscriptions::PlanChangeServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "플랜변경테스트 학원", onboarding_step: 6)
    @subscription = Subscription.create!(
      tenant: @tenant, plan: :light, status: :active,
      trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago,
      current_period_start: 10.days.ago, current_period_end: 20.days.from_now
    )
    @service = Subscriptions::PlanChangeService
  end

  # == 상향: 즉시 적용·기간 유지 ==
  test "상향(light→standard)은 즉시 plan 전환하고 결제 기간을 유지한다" do
    period_end = @subscription.current_period_end

    result = @service.change!(@subscription, plan: :standard,
                              operated_by: "01033334444", reason: "원생 증가")

    assert result.success?
    assert result.applied?
    assert_not result.pending?
    assert_equal "standard", @subscription.reload.plan
    assert_equal period_end, @subscription.current_period_end # 기간 유지
    event = @subscription.subscription_events.plan_changed.sole
    assert_equal "upgrade", event.detail_hash["direction"]
    assert_equal "light", event.detail_hash["from"]
    assert_equal "원생 증가", event.detail_hash["reason"]
    assert_equal "010-****-4444", event.operated_by # TEN-003 마스킹
  end

  # == 하향: 익월(current_period_end) 적용 — plan 컬럼은 유지 ==
  test "하향(standard→light)은 plan을 유지하고 effective_on=기간 말 pending 이벤트를 남긴다" do
    @subscription.update!(plan: :standard)
    effective_on = @subscription.current_period_end.to_date

    result = @service.change!(@subscription, plan: :light,
                              operated_by: "admin@wonbikok.kr", reason: "원생 감소")

    assert result.success?
    assert result.pending?
    assert_not result.applied?
    assert_equal "standard", @subscription.reload.plan # 아직 유지
    event = @subscription.pending_downgrade
    assert_equal "light", event.detail_hash["to"]
    assert_equal effective_on.iso8601, event.detail_hash["effective_on"]
    assert_equal "pending", event.detail_hash["status"]
  end

  test "pending 하향은 결제 갱신(force) 시 확정되어 plan이 전환된다" do
    @subscription.update!(plan: :standard) # 하향 대상 플랜
    @service.change!(@subscription, plan: :light, operated_by: "admin", reason: "축소")

    applied = @service.apply_pending_downgrade_for!(@subscription, force: true)

    assert applied
    assert_equal "light", @subscription.reload.plan
    events = @subscription.subscription_events.plan_changed.order(:id)
    assert_equal 2, events.count
    assert_equal "applied", events.last.detail_hash["status"]
    assert_nil @subscription.reload.pending_downgrade # 대기 소멸
  end

  test "pending 하향은 effective_on 경과 전 배치 적용에서 유지된다" do
    @subscription.update!(plan: :standard) # 하향 대상 플랜
    @service.change!(@subscription, plan: :light, operated_by: "admin", reason: "축소")

    assert_not @service.apply_pending_downgrade_for!(@subscription, on: Date.current - 1)
    assert_equal "standard", @subscription.reload.plan
    assert @service.apply_pending_downgrade_for!(@subscription, on: @subscription.current_period_end.to_date)
    assert_equal "light", @subscription.reload.plan
  end

  test "apply_due_downgrades!는 기간 경과분 하향만 일괄 확정한다(3-S recurring 진입점)" do
    due_tenant = Tenant.create!(name: "경과하향학원", onboarding_step: 6)
    due = Subscription.create!(
      tenant: due_tenant, plan: :standard, status: :past_due,
      trial_started_at: 60.days.ago, trial_ends_at: 30.days.ago,
      current_period_start: 40.days.ago, current_period_end: 10.days.ago # 이미 경과
    )
    @service.change!(due, plan: :light, operated_by: "admin", reason: "축소")
    @subscription.update!(plan: :standard) # 하향 대상 플랜(미경과 구독)
    @service.change!(@subscription, plan: :light, operated_by: "admin", reason: "축소") # 미경과

    applied = @service.apply_due_downgrades!(on: Date.current)

    assert_includes applied, due
    assert_not_includes applied, @subscription
    assert_equal "light", due.reload.plan
    assert_equal "standard", @subscription.reload.plan
  end

  # == 체험 중 플랜 변경: 상하향 모두 즉시 적용(기간 개념 없음 — PRD 11.2 만료 시 선택) ==
  test "체험 중 플랜 변경은 하향이라도 즉시 적용된다" do
    @subscription.update!(status: :trial, plan: :standard)

    result = @service.change!(@subscription, plan: :light,
                              operated_by: "admin", reason: "라이트로 시작")

    assert result.success?
    assert result.applied?
    assert_equal "light", @subscription.reload.plan
  end

  # == 검증·거절(ADM-001) ==
  test "사유가 없으면 변경이 거절되고 이벤트가 남지 않는다(ADM-001)" do
    result = @service.change!(@subscription, plan: :standard, operated_by: "admin", reason: "  ")

    assert_not result.success?
    assert_equal "light", @subscription.reload.plan
    assert_empty @subscription.subscription_events
    assert @subscription.errors.of_kind?(:base, :plan_change_reason_blank)
  end

  test "알 수 없는 플랜·동일 플랜 변경은 거절된다" do
    result = @service.change!(@subscription, plan: :premium, operated_by: "admin", reason: "테스트")
    assert_not result.success?
    assert @subscription.errors.of_kind?(:base, :plan_unknown)

    result = @service.change!(@subscription, plan: :light, operated_by: "admin", reason: "같음")
    assert_not result.success?
    assert @subscription.errors.of_kind?(:base, :plan_unchanged)
    assert_empty @subscription.subscription_events
  end
end
