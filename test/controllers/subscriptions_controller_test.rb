require "test_helper"

# 구독 화면 컨트롤러 테스트 — W4 F8 (단일 리소스 show).
# 라우트는 3-S 결선(`resource :subscription, only: :show`) 기준.
# 뷰 단정은 DB 파생 텍스트(숫자·일자·마스킹)만 — subscriptions.* i18n 키는 3-S 병합(f4 패턴 준용).
class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant, @user = create_owner_user(name: "구독화면테스트 학원")
    log_in(@user)
  end

  def create_subscription(tenant, status: :trial, plan: :light, trial_ends_in: Subscription::TRIAL_DAYS)
    Subscription.create!(
      tenant: tenant, plan: plan, status: status,
      trial_started_at: trial_ends_in.days.ago, trial_ends_at: trial_ends_in.days.from_now,
      current_period_start: trial_ends_in.days.ago, current_period_end: trial_ends_in.days.from_now
    )
  end

  test "미인증 구독 화면 접근은 로그인으로 리다이렉트된다" do
    delete session_url

    get subscription_url
    assert_redirected_to new_session_path
  end

  test "구독 화면은 플랜·상한·이력을 표시한다" do
    subscription = create_subscription(@tenant)
    create_student_with_guardian(tenant: @tenant) # 재원 1명
    subscription.subscription_events.create!(event_type: :trial_started,
                                             amount: nil, detail: { days: 30 }.to_json,
                                             operated_by: "01012345678")

    get subscription_url

    assert_response :ok
    assert_select "h1" # 화면 헤더 존재
    # SUB-001 상한 표시 — DB 파생 수치(재원 1 / light 30)
    assert_match "1", response.body
    assert_match "30", response.body
    assert_match "010-****-5678", response.body # TEN-003 처리자 마스킹 표시
  end

  test "TEN-001 화면에는 자기 테넌트 구독 수치만 표시된다" do
    create_subscription(@tenant, status: :active, plan: :light) # 비체험 — effective_plan = light(30)
    other_tenant = Tenant.create!(name: "타테넌트학원", onboarding_step: 6)
    create_subscription(other_tenant, status: :active, plan: :standard)
    create_student_with_guardian(tenant: @tenant, name: "우리원생")

    get subscription_url

    assert_response :ok
    # 상한 수치는 자기 집계(재원 1명·light 30) — 원생명은 수치 외 미표시, 타 테넌트(standard 70) 수치 노출 금지
    assert_match "/ 30명", response.body
    assert_no_match "70명", response.body
  end

  test "past_due 구독은 SUB-003 보관 만료일 카운트다운 배너를 표시한다" do
    subscription = create_subscription(@tenant, status: :active)

    travel_to Time.zone.parse("2026-11-18 10:00") do
      3.times { Subscriptions::RetryPolicyService.record_failure!(subscription) }
    end

    assert subscription.reload.past_due?
    get subscription_url

    assert_response :ok
    assert_match "2026-12-18", response.body # 데이터 보관 만료일(l() DB 파생 일자)
  end

  test "pending 하향이 있으면 적용 예정 플랜이 표시된다" do
    subscription = create_subscription(@tenant, status: :active)
    subscription.subscription_events.create!(
      event_type: :plan_changed,
      detail: { "direction" => "downgrade", "from" => "light", "to" => "light",
                "effective_on" => (Date.current + 5).iso8601, "status" => "pending" }.to_json
    )

    get subscription_url

    assert_response :ok
    assert_match (Date.current + 5).iso8601, response.body
  end

  # C-2 회귀 고정(3-S 병합 완료 후): 관리자 체험 연장(trial_extended) 이벤트가
  # 원장 구독 화면 이력에서 라벨로 정상 렌더된다 — enum 전수×키 존재 테스트의 렌더 보강.
  test "trial_extended 이벤트 라벨이 구독 이력에 정상 렌더된다(C-2)" do
    subscription = create_subscription(@tenant, status: :active)
    subscription.subscription_events.create!(
      event_type: :trial_extended,
      detail: { "days" => 15 }.to_json, operated_by: "admin@wonbikok.kr"
    )

    get subscription_url

    assert_response :ok
    assert_match I18n.t("subscriptions.events.trial_extended"), response.body
    assert_no_match "translation_missing", response.body # C-2 재발 방지 — 미번역 렌더 금지
  end

  test "구독이 없는 레거시 계정은 빈 상태 안내를 받는다" do
    get subscription_url

    assert_response :ok
    assert_select "h1"
  end
end
