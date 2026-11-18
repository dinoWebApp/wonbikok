require "test_helper"

# 구독·구독 이벤트 모델 테스트 — W4 F8 (SUB-001 상한 판정·체험 D-7·플랜 게이팅·장부 불변).
# 시그니처는 01_plan §2 고정값 기준. TEN-001: tenant 1:1 필수.
class SubscriptionTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "구독모델테스트 학원", onboarding_step: 6)
    @subscription = create_subscription(@tenant, plan: :light, status: :trial)
  end

  def create_subscription(tenant, plan:, status:, trial_ends_in: Subscription::TRIAL_DAYS, **attrs)
    Subscription.create!({
      tenant: tenant, plan: plan, status: status,
      trial_started_at: Time.current, trial_ends_at: trial_ends_in.days.from_now,
      current_period_start: Time.current, current_period_end: trial_ends_in.days.from_now
    }.merge(attrs))
  end

  # == TEN-001: 테넌시 1:1 격리 ==
  test "TEN-001 tenant 없이는 생성할 수 없고, 테넌트당 구독은 1개다" do
    subscription = Subscription.new(plan: :light, status: :trial)
    assert_not subscription.valid?
    assert subscription.errors.of_kind?(:tenant, :blank)

    duplicate = Subscription.new(tenant: @tenant, plan: :light, status: :active)
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:tenant_id, :taken)
  end

  # == SUB-001: 플랜 원생 수 상한 판정 (11.1 — light 30·standard 70) ==
  test "SUB-001 light 상한 30명은 30명에서 도달하고 29명에서 미도달이다" do
    @subscription.update!(status: :active) # effective_plan = light(체험 중 스탠다드 개방 제외)
    assert @subscription.students_limit_reached?(30)
    assert_not @subscription.students_limit_reached?(29)
    assert_equal 30, @subscription.students_limit
  end

  test "SUB-001 standard 상한은 70명이다" do
    @subscription.update!(plan: :standard)
    assert_equal 70, @subscription.students_limit
    assert_not @subscription.students_limit_reached?(70 - 1)
    assert @subscription.students_limit_reached?(70)
  end

  test "SUB-001 체험 중 유효 플랜은 스탠다드 전체 개방이다(PRD 11.2)" do
    assert_equal :standard, @subscription.effective_plan
    assert_equal 70, @subscription.students_limit

    @subscription.update!(status: :active)
    assert_equal :light, @subscription.effective_plan
    assert_equal 30, @subscription.students_limit
  end

  # == 체험 잔여일·D-7 판정 ==
  test "체험 잔여일은 종료일까지 일 단위로 계산된다" do
    assert_equal Subscription::TRIAL_DAYS, @subscription.trial_remain_days
    assert_equal 7, create_subscription(Tenant.create!(name: "잔여일학원"),
                                        plan: :light, status: :trial,
                                        trial_ends_in: 7).trial_remain_days
  end

  test "체험 종료 경과 시 잔여일은 음수, trial_ends_at 미설정이면 nil이다" do
    expired = create_subscription(Tenant.create!(name: "체험경과학원"),
                                  plan: :light, status: :past_due,
                                  trial_ends_in: -3)
    assert_equal(-3, expired.trial_remain_days)
    assert_nil Subscription.new(status: :active, plan: :light).trial_remain_days
  end

  test "trial_expiring? 잔여 7일은 임박(D-7), 8일은 아니다" do
    soon = create_subscription(Tenant.create!(name: "D7학원"),
                               plan: :light, status: :trial, trial_ends_in: 7)
    safe = create_subscription(Tenant.create!(name: "D8학원"),
                               plan: :light, status: :trial, trial_ends_in: 8)
    assert soon.trial_expiring?(within: 7.days)
    assert_not safe.trial_expiring?(within: 7.days)
    assert safe.trial_expiring?(within: 30.days)
  end

  test "trial_expiring? 종료 당일은 임박, 경과·비체험 상태는 false다" do
    today = create_subscription(Tenant.create!(name: "D0학원"),
                                plan: :light, status: :trial, trial_ends_in: 0)
    expired = create_subscription(Tenant.create!(name: "경과학원"),
                                  plan: :light, status: :trial, trial_ends_in: -1)
    active = create_subscription(Tenant.create!(name: "활성학원"),
                                 plan: :light, status: :active, trial_ends_in: 3)
    assert today.trial_expiring?
    assert_not expired.trial_expiring?
    assert_not active.trial_expiring?
  end

  test "trial_expiring 스코프는 체험 종료 임박 구간만 반환한다(3-S recurring D-7 잡 진입점)" do
    soon = create_subscription(Tenant.create!(name: "스코프D5학원"),
                               plan: :light, status: :trial, trial_ends_in: 5)
    create_subscription(Tenant.create!(name: "스코프D20학원"),
                        plan: :light, status: :trial, trial_ends_in: 20)
    create_subscription(Tenant.create!(name: "스코프활성학원"),
                        plan: :light, status: :active, trial_ends_in: 5)

    assert_includes Subscription.trial_expiring, soon
    assert_equal 1, Subscription.trial_expiring.count
  end

  # == 상태 enum 검증 ==
  test "상태·플랜은 정의된 값만 허용된다(validate)" do
    invalid = Subscription.new(tenant: @tenant, plan: :light, status: "unknown")
    assert_not invalid.valid?
    assert invalid.errors.of_kind?(:status, :inclusion)

    invalid_plan = Subscription.new(tenant: @tenant, plan: :premium, status: :active)
    assert_not invalid_plan.valid?
    assert invalid_plan.errors.of_kind?(:plan, :inclusion)
  end

  # == pending 하향 판정(plan_changed 장부 — 최신 이벤트 1개로 판정) ==
  test "pending_downgrade는 대기 중 하향 이벤트를 반환하고 applied면 nil이다" do
    assert_nil @subscription.pending_downgrade

    @subscription.subscription_events.create!(
      event_type: :plan_changed,
      detail: { "direction" => "downgrade", "from" => "light", "to" => "light",
                "effective_on" => Date.current.iso8601, "status" => "pending" }.to_json
    )
    pending = @subscription.pending_downgrade
    assert_not_nil pending
    assert_equal "pending", pending.detail_hash["status"]

    # 확정(applied) 이벤트가 더 최신이면 대기 없음 — append-only 장부 최신 우선 판정
    @subscription.subscription_events.create!(
      event_type: :plan_changed,
      detail: { "direction" => "downgrade", "from" => "light", "to" => "light",
                "status" => "applied" }.to_json
    )
    assert_nil @subscription.pending_downgrade
  end

  # == SubscriptionEvent 장부 ==
  test "이벤트 타입은 정의된 8종만 허용된다" do
    event = @subscription.subscription_events.new(event_type: "hacked")
    assert_not event.valid?
    assert event.errors.of_kind?(:event_type, :inclusion)

    %w[trial_started manual_payment payment_failed retry past_due suspended
       plan_changed refund].each do |type|
      assert @subscription.subscription_events.build(event_type: type).valid?
    end
  end

  test "TEN-003 처리자 휴대폰번호는 마스킹 저장되고 비전화 값은 원문 보존된다" do
    event = @subscription.subscription_events.create!(event_type: :manual_payment,
                                                      operated_by: "01012345678")
    assert_equal "010-****-5678", event.reload.operated_by

    admin = @subscription.subscription_events.create!(event_type: :plan_changed,
                                                      operated_by: "admin@wonbikok.kr")
    assert_equal "admin@wonbikok.kr", admin.reload.operated_by
  end

  test "detail_hash는 JSON 파싱 실패 시 빈 해시를 반환한다(장부 열람 보호)" do
    broken = @subscription.subscription_events.create!(event_type: :manual_payment, detail: "not-json{")
    assert_equal({}, broken.detail_hash)

    ok = @subscription.subscription_events.create!(event_type: :manual_payment,
                                                   detail: { "attempt" => 1 }.to_json)
    assert_equal({ "attempt" => 1 }, ok.detail_hash)
  end

  # C-2 재발 방지: 이벤트 enum 전수 × 원장 화면 라벨 키(subscriptions.events.*) 존재 대조 —
  # enum 추가 시 i18n 누락을 테스트에서 조기 검출한다(동적 t("subscriptions.events.#{type}") 대응).
  test "모든 이벤트 타입의 원장 화면 라벨 i18n 키가 존재한다(C-2)" do
    SubscriptionEvent.event_types.each_key do |type|
      label = I18n.t("subscriptions.events.#{type}")
      assert_not label.to_s.include?("translation missing"),
                 "subscriptions.events.#{type} 키가 config/locales/ko.yml에 없습니다"
    end
  end

  test "amount는 0 이상 정수만 허용된다" do
    assert @subscription.subscription_events.build(event_type: :manual_payment, amount: 0).valid?
    assert_not @subscription.subscription_events.build(event_type: :manual_payment, amount: -1).valid?
  end
end
