require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "가입 성공 시 Tenant와 User가 함께 생성되고 스텝 2로 이동한다" do
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
  end

  test "비밀번호가 짧으면 422로 응답하고 테넌트가 생성되지 않는다" do
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
end
