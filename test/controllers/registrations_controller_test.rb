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
end
