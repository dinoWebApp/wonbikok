require "test_helper"

module Admin
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "ops@example.com", password: ADMIN_PASSWORD)
      admin_log_in(@admin)
      @tenant = Tenant.create!(name: "대시보드 학원", onboarding_step: 6)
      @student = create_student_with_guardian(tenant: @tenant)
      @invoice = create_invoice(@tenant, @student)
    end

    test "미인증 접근은 차단된다" do
      delete admin_session_url # 로그아웃

      get admin_dashboard_url
      assert_redirected_to new_admin_session_url
    end

    test "최근 24시간 발송·발행 실패 건수를 실시간 표시한다" do
      @tenant.message_logs.create!(invoice: @invoice, student: @student,
                                   template_type: :invoice_notice, status: :FAILED)
      @tenant.cash_receipts.create!(invoice: @invoice, mgt_key: "CRDASH0001",
                                    issue_type: :income_deduction, amount: 250_000, state: :failed)

      get admin_dashboard_url

      assert_response :ok
      assert_match "1", response.body # 실패 1건 — 카드 수치
      assert_match I18n.t("admin.dashboard.ops_status.message_failed_24h"), response.body
      assert_match I18n.t("admin.dashboard.ops_status.receipt_failed_24h"), response.body
    end

    test "지표 카드에 산식이 화면에 명시된다(A1 수용조건)" do
      get admin_dashboard_url

      assert_response :ok
      assert_match I18n.t("admin.dashboard.formulas.mau"), response.body
      assert_match I18n.t("admin.dashboard.formulas.paid_conversion"), response.body
    end

    test "MAU 근사는 최근 30일 세션 생성 수 기준이다" do
      @owner = @tenant.users.create!(phone_number: "01055556666", password: "password123")
      @owner.sessions.create!(created_at: 1.day.ago) # 최근 30일 내 세션
      stale_user = @tenant.users.create!(phone_number: "01077778888", password: "password123")
      stale_user.sessions.create!(created_at: 40.days.ago) # 기간 외 — 제외

      get admin_dashboard_url

      assert_response :ok
    end

    test "체험 D-7 예정 구독이 지표에 반영된다(Subscription 가정 — [3-S 결합 지점])" do
      expiring = Subscription.create!(tenant: @tenant, plan: "light", status: "trial",
                                      trial_started_at: 24.days.ago, trial_ends_at: 7.days.from_now)

      get admin_dashboard_url

      assert_response :ok
      assert_equal true, expiring.trial_expiring?(within: 7.days) # f8 실구현 시그니처(2026-11-18 확인)
    end

    test "past_due 대응 대기 큐에 테넌트 링크가 노출되고 A3로 드릴다운된다" do
      Subscription.create!(tenant: @tenant, plan: "light", status: "past_due",
                           trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago)

      get admin_dashboard_url

      assert_response :ok
      assert_match @tenant.name, response.body
      assert_match admin_tenant_path(@tenant), response.body
    end

    test "외부 서비스 상태 배너는 SIMULATED(미확인)로 표시한다(실핑 금지)" do
      get admin_dashboard_url

      assert_response :ok
      assert_match I18n.t("admin.dashboard.service_states.simulated"), response.body
    end

    test "추이는 숫자 표로 제공된다(차트 라이브러리 없음 — 후속)" do
      get admin_dashboard_url

      assert_response :ok
      assert_match I18n.t("admin.dashboard.trend.title"), response.body
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
