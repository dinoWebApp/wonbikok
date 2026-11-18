require "test_helper"

module Admin
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "ops@example.com", password: ADMIN_PASSWORD)
    end

    test "미인증 관리자 페이지 접근은 로그인으로 리다이렉트한다" do
      get admin_tenants_url

      assert_redirected_to new_admin_session_url
    end

    test "1단계 성공 시 OTP 2단계 폼을 렌더링한다" do
      post admin_session_url, params: { admin_session: { email: @admin.email, password: ADMIN_PASSWORD } }

      assert_response :ok
      assert_match I18n.t("admin.sessions.otp_title"), response.body
    end

    test "1단계 실패 시 422와 단일 오류 문구로 응답한다" do
      post admin_session_url, params: { admin_session: { email: @admin.email, password: "wrong-pass" } }

      assert_response :unprocessable_entity
      assert_match I18n.t("admin.sessions.invalid_credentials"), response.body
    end

    test "존재하지 않는 이메일도 동일 문구로 응답한다(열거 방지)" do
      post admin_session_url, params: { admin_session: { email: "ghost@example.com", password: "wrong-pass" } }

      assert_response :unprocessable_entity
      assert_match I18n.t("admin.sessions.invalid_credentials"), response.body
    end

    test "2단계 OTP 성공 시 로그인되고 감사 로그가 남는다" do
      post admin_session_url, params: { admin_session: { email: @admin.email, password: ADMIN_PASSWORD } }
      post admin_session_otp_url, params: { otp_code: Admin::OtpService.current_code(@admin) }

      assert_redirected_to admin_dashboard_url
      follow_redirect!
      assert_response :ok

      assert_equal @admin.id, session[:admin_user_id]
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "login")
      assert_equal 0, @admin.reload.failed_attempts
    end

    test "2단계 OTP 실패 시 422로 재시도 폼을 렌더링하고 실패가 기록된다" do
      post admin_session_url, params: { admin_session: { email: @admin.email, password: ADMIN_PASSWORD } }

      post admin_session_otp_url, params: { otp_code: "000000" }

      assert_response :unprocessable_entity
      assert_match I18n.t("admin.sessions.invalid_otp"), response.body
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "login_failure", detail: { "stage" => "otp" })
      assert_nil session[:admin_user_id]
    end

    test "5회 실패(1·2단계 합산) 시 잠기고 이후 올바른 자격으로도 로그인할 수 없다" do
      # 1단계 비밀번호 실패 3회
      3.times do
        post admin_session_url, params: { admin_session: { email: @admin.email, password: "wrong-pass" } }
        assert_response :unprocessable_entity
      end
      # 2단계 OTP 실패 2회 → 5회째에 잠금
      post admin_session_url, params: { admin_session: { email: @admin.email, password: ADMIN_PASSWORD } }
      2.times do
        post admin_session_otp_url, params: { otp_code: "000000" }
        assert_response :unprocessable_entity
      end

      assert @admin.reload.locked?
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "account_locked")

      # 잠금 후 올바른 자격 입력도 잠금 안내로 차단
      post admin_session_url, params: { admin_session: { email: @admin.email, password: ADMIN_PASSWORD } }
      assert_response :unprocessable_entity
      assert_match I18n.t("admin.sessions.locked_notice"), response.body
      assert_nil session[:admin_user_id]
    end

    test "2단계 도중 세션 만료(예비 키 부재) 시 1단계로 되돌린다" do
      post admin_session_otp_url, params: { otp_code: "123456" }

      assert_redirected_to new_admin_session_url
    end

    test "로그아웃 후 보호 경로 접근이 차단된다" do
      admin_log_in(@admin)

      delete admin_session_url
      assert_redirected_to new_admin_session_url

      get admin_tenants_url
      assert_redirected_to new_admin_session_url
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "logout")
    end

    private

    def admin_log_in(admin_user, password: ADMIN_PASSWORD)
      post admin_session_url, params: { admin_session: { email: admin_user.email, password: password } }
      assert_response :ok
      post admin_session_otp_url, params: { otp_code: Admin::OtpService.current_code(admin_user) }
      assert_redirected_to admin_dashboard_url
    end
  end
end
