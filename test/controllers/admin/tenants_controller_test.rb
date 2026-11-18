require "test_helper"

module Admin
  class TenantsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "ops@example.com", password: ADMIN_PASSWORD)
      admin_log_in(@admin)
      @tenant = Tenant.create!(name: "검색대상 학원", business_number: "1234567890",
                               owner_name: "김원장", onboarding_step: 6)
      @owner = @tenant.users.create!(phone_number: "01033334444", password: "password123",
                                     last_login_at: 1.hour.ago)
      @subscription = Subscription.create!(tenant: @tenant, plan: "light", status: "trial",
                                           trial_started_at: 10.days.ago, trial_ends_at: 20.days.from_now)
    end

    test "미인증 접근은 차단된다" do
      delete admin_session_url

      get admin_tenants_url
      assert_redirected_to new_admin_session_url
    end

    test "목록은 상호·사업자번호·ID 통합 검색 결과를 마스킹해 표시한다(ADM-002)" do
      get admin_tenants_url, params: { q: "검색대상" }

      assert_response :ok
      assert_match "검색대상 학원", response.body
      # 마스킹 형태 표시 — 사업자번호 원문 미노출
      assert_match "123-**-***90", response.body
      assert_no_match "1234567890", response.body
      # 휴대폰번호 원문 미노출(TEN-003)
      assert_match "010-****-4444", response.body
      assert_no_match "01033334444", response.body
    end

    test "목록은 사업자번호 부분 일치로 검색한다" do
      get admin_tenants_url, params: { q: "6789" }

      assert_response :ok
      assert_match "검색대상 학원", response.body
    end

    test "목록은 교습소 ID로 검색한다" do
      get admin_tenants_url, params: { q: @tenant.id.to_s }

      assert_response :ok
      assert_match "검색대상 학원", response.body
    end

    test "검색 결과가 없으면 빈 상태를 표시한다" do
      get admin_tenants_url, params: { q: "없는상호" }

      assert_response :ok
      # ERB 이스케이프('→&#39;) 반영 — 질의어와 안내 문구를 나눠 단정
      assert_match "없는상호", response.body
      assert_match "검색 결과가 없습니다", response.body
    end

    test "상세 열람 시 개인정보 접근 로그를 기록한다(A0)" do
      get admin_tenant_url(@tenant)

      assert_response :ok
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "personal_info_viewed",
                              target_type: "Tenant", target_id: @tenant.id)
    end

    test "상세는 플랜·체험 잔여일·원생 수·마지막 활동을 표시한다" do
      get admin_tenant_url(@tenant)

      assert_response :ok
      assert_match I18n.t("admin.subscription_statuses.plan.light"), response.body
      assert_match I18n.t("admin.subscription_statuses.status.trial"), response.body
      assert_match @owner.phone_number.to_s.last(4), response.body # 마스킹 뒷자리만
      # ADM-002 — 상세 화면도 개인정보 원문 미노출
      assert_no_match "01033334444", response.body
      assert_no_match "1234567890", response.body
    end

    test "상세 타임라인에 가입·감사 로그가 시간순으로 표시된다" do
      AuditLog.record!(admin_user: @admin, action: "personal_info_viewed", target: @tenant,
                       created_at: 5.minutes.ago)

      get admin_tenant_url(@tenant)

      assert_response :ok
      assert_match I18n.t("admin.timeline.title"), response.body
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
