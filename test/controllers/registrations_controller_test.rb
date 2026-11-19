require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "가입 성공 시 Tenant와 User가 함께 생성되고 스텝 2로 이동한다" do
    verify_signup_phone!("01099990000") # F10 REF-006: 검증 완료 레코드 사전 생성(헬퍼 — 사유 test_helper 주석)
    assert_difference [ "Tenant.count", "User.count" ], 1 do
      post registration_url, params: {
        tenant: { name: "새 학원" },
        user: { phone_number: "01099990000", password: "password123", password_confirmation: "password123" }
      }
    end

    assert_redirected_to onboarding_step_path(2)
    tenant = Tenant.find_by(name: "새 학원")
    assert_equal 1, tenant.onboarding_step
    assert_equal "01099990000", tenant.users.sole.phone_number
    # F10: 소비(consume!) 완료 — 재사용 불가
    assert SignupVerification.consumed.exists?
  end

  test "비밀번호가 짧으면 422로 응답하고 테넌트가 생성되지 않는다" do
    verify_signup_phone!("01099990001")
    assert_no_difference [ "Tenant.count", "User.count" ] do
      post registration_url, params: {
        tenant: { name: "새 학원" },
        user: { phone_number: "01099990001", password: "pass123", password_confirmation: "pass123" }
      }
    end

    assert_response :unprocessable_entity
  end

  # 중복 번호 예외: 동시 가입 레이스(WARNING-6) — DB 유니크 제약도 422 안내로 응답
  test "WARNING-6 유니크 제약 위반 가입은 422 안내로 응답한다" do
    create_owner_user(phone_number: "01088887777")
    verify_signup_phone!("01088887777")
    params = {
      tenant: { name: "레이스 학원" },
      user: { phone_number: "01088887777", password: "password123", password_confirmation: "password123" }
    }

    User.class_eval do
      alias_method :original_valid_without_skip, :valid?
      define_method(:valid?) { |*| true }
    end
    begin
      post registration_url, params: params
    ensure
      User.class_eval do
        remove_method :valid?
        alias_method :valid?, :original_valid_without_skip
        remove_method :original_valid_without_skip
      end
    end

    assert_response :unprocessable_entity
    assert_match "이미 가입된 휴대폰번호", response.body
  end

  # == F8: 가입 시 30일 무료체험 자동 시작(W4) ==
  test "F8 가입 성공 시 30일 체험 구독과 trial_started 이벤트가 함께 생성된다" do
    verify_signup_phone!("01077770000")
    assert_difference [ "Tenant.count", "User.count", "Subscription.count", "SubscriptionEvent.count" ], 1 do
      post registration_url, params: {
        tenant: { name: "체험자동시작 학원" },
        user: { phone_number: "01077770000", password: "password123", password_confirmation: "password123" }
      }
    end

    assert_redirected_to onboarding_step_path(2)
    tenant = Tenant.find_by(name: "체험자동시작 학원")
    subscription = Subscription.find_by(tenant_id: tenant.id) # has_one 역방향(3-S) 비의존
    assert_not_nil subscription
    assert_equal "trial", subscription.status
    assert_equal "standard", subscription.plan # 체험 중 스탠다드 개방(PRD 11.2)
    assert_equal Subscription::TRIAL_DAYS, subscription.trial_remain_days
    assert_equal "trial_started", subscription.subscription_events.sole.event_type
  end

  test "F8 체험 시작 실패는 가입을 차단하지 않는다(로그만 기록)" do
    original = Subscriptions::TrialService.method(:start_for!)
    Subscriptions::TrialService.define_singleton_method(:start_for!) do |*_|
      raise StandardError, "외부 장애 시나리오"
    end
    verify_signup_phone!("01077770002")

    assert_difference [ "Tenant.count", "User.count" ], 1 do
      assert_no_difference "Subscription.count" do
        post registration_url, params: {
          tenant: { name: "체험실패학원" },
          user: { phone_number: "01077770002", password: "password123", password_confirmation: "password123" }
        }
      end
    end

    assert_redirected_to onboarding_step_path(2)
  ensure
    Subscriptions::TrialService.define_singleton_method(:start_for!, original)
  end

  # ==================================================================
  # F10 REF-006: 가입은 휴대폰 인증 완료 시에만 가능(서버 검증 — DB 원천)
  # ==================================================================
  test "REF-006 미검증 가입 제출은 422로 거부되고 테넌트가 생성되지 않는다" do
    assert_no_difference [ "Tenant.count", "User.count" ] do
      post registration_url, params: {
        tenant: { name: "미검증 학원" },
        user: { phone_number: "01055551111", password: "password123", password_confirmation: "password123" }
      }
    end

    assert_response :unprocessable_entity
    assert_match "휴대폰 인증", response.body
  end

  test "REF-006 제출 전화와 검증 전화가 다르면 가입이 거부된다" do
    verify_signup_phone!("01044440000") # 1111로 가입 제출
    assert_no_difference [ "Tenant.count", "User.count" ] do
      post registration_url, params: {
        tenant: { name: "전화불일치 학원" },
        user: { phone_number: "01044441111", password: "password123", password_confirmation: "password123" }
      }
    end

    assert_response :unprocessable_entity
  end

  test "REF-006 가입 성공 시 소비(consume)된 검증 레코드는 재검증 없이 재사용될 수 없다" do
    verify_signup_phone!("01066660000")
    post registration_url, params: {
      tenant: { name: "첫가입 학원" },
      user: { phone_number: "01066660000", password: "password123", password_confirmation: "password123" }
    }
    assert_redirected_to onboarding_step_path(2)

    verification = SignupVerification.find_by(phone_number: "01066660000")
    assert verification.consumed?
    # 소비된 레코드로는 consume!이 실패 — 서비스 단위 재사용 방지 근거
    assert_nil Signup::PhoneVerificationService.consume!("01066660000")
  end

  # 1차 리뷰 Tester 제안(05_review): 검증 직후 제출 사이 TTL(5분)이 경과한 경계 —
  # usable_for_signup?(verified·미소비·미만료)이 create 통합 경로에서 거절로 이어지는지 검증.
  test "REF-006 검증 완료 직후 만료가 경과하면 가입이 거부된다(통합 경계)" do
    verify_signup_phone!("01055552222")
    SignupVerification.find_by(phone_number: "01055552222").update!(expires_at: 1.second.ago) # 만료 경과

    assert_no_difference [ "Tenant.count", "User.count" ] do
      post registration_url, params: {
        tenant: { name: "만료인증 학원" },
        user: { phone_number: "01055552222", password: "password123", password_confirmation: "password123" }
      }
    end

    assert_response :unprocessable_entity
    assert_match "휴대폰 인증", response.body
    assert_not SignupVerification.find_by(phone_number: "01055552222").consumed? # 미소비 — 재인증 후 가입 가능
  end

  # == F10 인증 액션(JSON — Stimulus fetch) ==
  test "REF-006 인증번호 발송·검증 액션이 검증 완료 상태를 기록한다" do
    with_fixed_verification_code("987654") do
      post registration_send_verification_url, params: { phone_number: "01012340000" }, as: :json
      assert_response :ok
      assert_equal "ok", response.parsed_body["status"]

      post registration_verify_url, params: { phone_number: "01012340000", code: "987654" }, as: :json
      assert_response :ok
      verification = SignupVerification.find_by(phone_number: "01012340000")
      assert verification.verified?
      assert_not verification.consumed?
    end
  end

  test "REF-006 잘못된 인증번호는 422와 오류 메시지를 반환한다" do
    with_fixed_verification_code("111111") do
      post registration_send_verification_url, params: { phone_number: "01012340001" }, as: :json
      post registration_verify_url, params: { phone_number: "01012340001", code: "222222" }, as: :json
      assert_response :unprocessable_entity
      assert_equal "error", response.parsed_body["status"]
    end
  end

  test "REF-006 잘못된 형식의 번호 발송은 422로 거부된다" do
    post registration_send_verification_url, params: { phone_number: "abc" }, as: :json
    assert_response :unprocessable_entity
  end

  test "REF-006 인증번호 재발송 레이트 리밋(1분 1회)은 429로 응답한다" do
    with_fixed_verification_code("333333") do
      post registration_send_verification_url, params: { phone_number: "01012340002" }, as: :json
      assert_response :ok
      post registration_send_verification_url, params: { phone_number: "01012340002" }, as: :json
      assert_response :too_many_requests
    end
  end

  # == F10 REF-001: 추천 코드 가입 매핑 ==
  test "REF-001 유효한 추천 코드로 가입하면 tenants에 직원 매핑·코드 스냅샷이 저장된다" do
    rep = SalesRep.create!(name: "영업A", email: "rep-code@example.com", password: "password123",
                           role: "sales")
    code = Referral::CodeService.issue_for!(rep)
    verify_signup_phone!("01022220000")

    assert_difference "Tenant.count", 1 do
      post registration_url, params: {
        tenant: { name: "추천가입 학원" },
        user: { phone_number: "01022220000", password: "password123", password_confirmation: "password123" },
        referral_code: code.downcase # 입력 정규화(대소문자 무관) 검증
      }
    end

    tenant = Tenant.find_by(name: "추천가입 학원")
    assert tenant.referred?
    assert_equal rep.id, tenant.referred_by_sales_rep_id
    assert_equal code, tenant.referral_code_snapshot
  end

  test "REF-001 만료된 추천 코드로의 가입은 422로 거절된다" do
    rep = SalesRep.create!(name: "영업B", email: "rep-expired@example.com", password: "password123",
                           role: "sales")
    code = Referral::CodeService.issue_for!(rep)
    ReferralCode.find_by(code: code).update!(expires_at: 1.minute.ago) # 만료
    verify_signup_phone!("01022220001")

    assert_no_difference "Tenant.count" do
      post registration_url, params: {
        tenant: { name: "만료코드 학원" },
        user: { phone_number: "01022220001", password: "password123", password_confirmation: "password123" },
        referral_code: code
      }
    end

    assert_response :unprocessable_entity
    assert_match "추천 코드", response.body
  end

  test "REF-001 존재하지 않는 추천 코드는 422 안내로 거절된다" do
    verify_signup_phone!("01022220002")
    assert_no_difference "Tenant.count" do
      post registration_url, params: {
        tenant: { name: "무효코드 학원" },
        user: { phone_number: "01022220002", password: "password123", password_confirmation: "password123" },
        referral_code: "ZZZZ9999"
      }
    end

    assert_response :unprocessable_entity
  end
end
