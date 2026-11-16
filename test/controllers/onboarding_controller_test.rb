require "test_helper"

class OnboardingControllerTest < ActionDispatch::IntegrationTest
  # CRITICAL-2: 가입 직후(step=1) 이탈자의 재로그인 재개가 400이 아니다
  test "CRITICAL-2 step=1 이탈자 재로그인 시 스텝 2로 재개된다" do
    tenant, user = create_owner_user(step: 1)
    log_in(user)

    assert_redirected_to onboarding_step_path(2)
    follow_redirect!
    assert_response :ok

    # 재로그인 후 루트 진입도 동일하게 재개된다
    delete session_url
    log_in(user)
    assert_redirected_to onboarding_step_path(2)

    get dashboard_path # 2026-11-04: 루트가 랜딩으로 이동 — 앱 홈 접근은 /dashboard 경유
    assert_redirected_to onboarding_step_path(2)
    follow_redirect!
    assert_response :ok
    assert_equal tenant.reload.onboarding_step, 1
  end

  test "step=3 진행자 재로그인 시 현재 스텝이 유지된다" do
    _tenant, user = create_owner_user(step: 3)

    log_in(user)

    assert_redirected_to onboarding_step_path(3)
    follow_redirect!
    assert_response :ok
  end

  test "온보딩 완료자 재로그인 시 온보딩 리다이렉트가 적용되지 않는다" do
    _tenant, user = create_owner_user(step: 6)
    log_in(user)

    assert_redirected_to dashboard_path # 2026-11-04: 루트가 랜딩으로 이동 — 앱 홈은 /dashboard

    get onboarding_step_path(2)
    assert_redirected_to dashboard_path
  end

  # WARNING-1: 스텝 우회 차단 — 현재 스텝+1 초과 접근은 현재 스텝으로 되돌린다
  test "WARNING-1 2스텝에서 4·5스텝 접근은 현재 이후 스텝으로 되돌려진다" do
    _tenant, user = create_owner_user(step: 2)
    log_in(user)

    get onboarding_step_path(4)
    assert_redirected_to onboarding_step_path(3)

    patch onboarding_step_path(5), params: { commit: "practice" }
    assert_redirected_to onboarding_step_path(3)
    assert_equal 2, Tenant.find_by(name: "테스트 학원").onboarding_step
  end

  # WARNING-1: 사업자 정보 빈값 제출은 422 + 필드별 오류
  test "사업자 정보 빈값 제출은 422로 거절된다" do
    _tenant, user = create_owner_user(step: 2)
    log_in(user)

    patch onboarding_step_path(2), params: { tenant: { name: "", business_number: "", business_type: "", owner_name: "" } }

    assert_response :unprocessable_entity
    assert_equal 2, Tenant.find_by(name: "테스트 학원").onboarding_step
  end

  test "사업자 정보 정상 제출은 스텝을 3으로 진행한다" do
    _tenant, user = create_owner_user(step: 2)
    log_in(user)

    patch onboarding_step_path(2), params: {
      tenant: { name: "테스트 학원", business_number: "123-45-67890", business_type: "교습소", owner_name: "김원장",
                biz_tel: "02-1234-5678", biz_type: "교육", email: "owner@example.com" }
    }

    assert_redirected_to onboarding_step_path(3)
    assert_equal "1234567890", Tenant.find_by(name: "테스트 학원").reload.business_number
  end

  # F5 바로빌 회원사 자동 가입 — 성공 시 barobill_member_id 저장(SIMULATED: test 환경 cert_key 공백)
  test "F5 사업자 정보 제출 시 바로빌 가입이 시도되고 member_id가 저장된다" do
    _tenant, user = create_owner_user(step: 2)
    log_in(user)

    patch onboarding_step_path(2), params: {
      tenant: { name: "테스트 학원", business_number: "123-45-67890", business_type: "교습소", owner_name: "김원장",
                biz_tel: "02-1234-5678", biz_type: "교육", email: "owner@example.com" }
    }

    tenant = Tenant.find_by(name: "테스트 학원")
    assert_redirected_to onboarding_step_path(3)
    assert_equal "wonbi#{tenant.id}", tenant.reload.barobill_member_id
    assert tenant.barobill_joined_at.present?
    assert tenant.cash_receipt_linked?
  end

  # F5 — RegistCorp 실패(어댑터 오류) 시에도 온보딩은 계속된다(재시도 가능)
  test "F5 바로빌 가입 실패 시에도 온보딩은 차단되지 않는다" do
    _tenant, user = create_owner_user(step: 2)
    log_in(user)
    Barobill::MemberService.define_singleton_method(:from_credentials) { raise Barobill::Error.new("NETWORK_ERROR", code: :network_error) }

    patch onboarding_step_path(2), params: {
      tenant: { name: "테스트 학원", business_number: "123-45-67890", business_type: "교습소", owner_name: "김원장",
                biz_tel: "02-1234-5678", biz_type: "교육", email: "owner@example.com" }
    }

    tenant = Tenant.find_by(name: "테스트 학원")
    assert_redirected_to onboarding_step_path(3)
    assert_nil tenant.reload.barobill_member_id
    assert tenant.cash_receipt_failed?
  ensure
    Barobill::MemberService.singleton_class.remove_method(:from_credentials)
  end

  # 5스텝: 연습 모드 선택 → 온보딩 완료 → 대시보드(연습 샘플 데이터, 외부 호출 없음)
  test "연습 모드 선택 시 온보딩이 완료되고 샘플 데이터가 생성된다" do
    tenant, user = create_owner_user(step: 5)
    log_in(user)

    assert_difference -> { tenant.students.count }, 10 do
      patch onboarding_step_path(5), params: { commit: "practice" }
    end

    assert_redirected_to dashboard_path # 2026-11-04: 루트가 랜딩으로 이동 — 온보딩 완료 후 앱 홈은 /dashboard
    assert tenant.reload.practice?
    assert_equal 6, tenant.onboarding_step
  end

  test "미인증 온보딩 접근은 로그인으로 리다이렉트된다" do
    get onboarding_step_path(2)

    assert_redirected_to new_session_path
  end
end
