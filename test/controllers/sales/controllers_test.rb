require "test_helper"

module Sales
  # 영업 직원 세션·대시보드 컨트롤러 테스트 (F10 — REF-005 스코프 격리·REF-007 정지 차단·5회 잠금).
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @rep = SalesRep.create!(name: "세션직원", email: "sales-session@example.com",
                              password: "sales-pass-123", role: "sales")
    end

    test "이메일+비밀번호로 로그인해 대시보드로 이동한다" do
      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }

      assert_redirected_to sales_dashboard_url
      get sales_dashboard_url
      assert_response :ok
      assert_match "세션직원", response.body
    end

    # B-1 재발 방지(뷰-컨트롤러 계약 고정): 로그인 폼 필드는 반드시 sales_session 스코프로
    # 렌더된다 — scope 누락 시 name="email" 최상위 제출로 ParameterMissing(400) 재발.
    test "로그인 폼은 sales_session 스코프 필드로 렌더되고 실제 제출이 동작한다" do
      get new_sales_session_url
      assert_response :ok
      assert_includes response.body, 'name="sales_session[email]"'
      assert_includes response.body, 'name="sales_session[password]"'

      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }
      assert_redirected_to sales_dashboard_url
    end

    test "REF-007 정지 계정은 비밀번호가 맞아도 로그인이 차단된다" do
      @rep.suspend!("부당 사용 정지")

      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }

      assert_response :unprocessable_entity
      assert_match "정지된 계정", response.body

      get sales_dashboard_url # 직접 접근도 차단
      assert_redirected_to new_sales_session_url
    end

    test "REF-007 정지 계정의 기존 세션도 대시보드 접근이 차단된다(세션 재확인 이중 방어)" do
      log_in_rep
      @rep.suspend!("정지 조치") # 로그인 후 정지

      get sales_dashboard_url

      assert_redirected_to new_sales_session_url
    end

    test "로그인 5회 실패 시 잠긴다(AdminUser 동일 규약)" do
      5.times do
        post sales_session_url, params: { sales_session: { email: @rep.email, password: "wrong-pass" } }
        assert_response :unprocessable_entity
      end

      assert @rep.reload.locked?
      # 정확한 비밀번호로도 잠금 상태에서는 로그인 불가
      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }
      assert_response :unprocessable_entity
      assert_match "잠겼습니다", response.body
    end

    test "로그아웃하면 대시보드 접근이 차단된다" do
      log_in_rep
      delete sales_session_url

      assert_redirected_to new_sales_session_url
      get sales_dashboard_url
      assert_redirected_to new_sales_session_url
    end

    test "관리자 세션과 별도 키를 사용하며 sales 로그인 시 세션 재발급으로 관리자 세션은 초기화된다" do
      admin = AdminUser.create!(email: "sales-admin@example.com", password: "admin-pass-123")
      post admin_session_url, params: { admin_session: { email: admin.email, password: "admin-pass-123" } }
      post admin_session_otp_url, params: { otp_code: Admin::OtpService.current_code(admin) }
      assert_redirected_to admin_dashboard_url

      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }
      assert_redirected_to sales_dashboard_url

      # sales 로그인은 reset_session으로 세션 고정을 방어(Admin 로그인과 동일 패턴) —
      # 같은 브라우저의 관리자 세션은 재로그인 필요(문서화된 트레이드오프)
      get sales_dashboard_url
      assert_response :ok
      get admin_dashboard_url
      assert_redirected_to new_admin_session_url
    end

    private

    def log_in_rep
      post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }
      assert_redirected_to sales_dashboard_url
    end
  end

  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @rep = SalesRep.create!(name: "대시직원", email: "sales-dash@example.com",
                              password: "sales-pass-123", role: "sales", title: "영업 이사")
      @other = SalesRep.create!(name: "타직원", email: "sales-dash-other@example.com",
                                password: "sales-pass-123", role: "sales")
      @my_tenant = Tenant.create!(name: "내추천 학원", onboarding_step: 6,
                                  referred_by_sales_rep: @rep)
      @other_tenant = Tenant.create!(name: "타추천 학원", onboarding_step: 6,
                                     referred_by_sales_rep: @other)
      @my_subscription = Subscription.create!(tenant: @my_tenant, plan: :light, status: :active)
      Subscription.create!(tenant: @other_tenant, plan: :standard, status: :active)
      log_in(@rep)
    end

    test "대시보드는 본인 데이터만 표시한다(REF-005 — 타 직원·타 피판매 제외)" do
      Referral::CommissionService.accrue_on_payment!(@my_subscription, 8_000)
      Subscription.find_by(tenant: @other_tenant)
                   .subscription_events.create!(event_type: :manual_payment, amount: 500_000)

      get sales_dashboard_url

      assert_response :ok
      assert_match "내추천 학원", response.body
      assert_no_match "타추천 학원", response.body
      assert_match "영업 이사", response.body # 직함 노출
    end

    test "비로그인 대시보드 접근은 로그인으로 리다이렉트된다" do
      delete sales_session_url

      get sales_dashboard_url
      assert_redirected_to new_sales_session_url
    end

    test "연도 선택 파라미터는 표시 가능 범위로 클램프된다" do
      get sales_dashboard_url, params: { year: "1999" }

      assert_response :ok # 클램프로 안전 처리 — 오류 없음
    end

    private

    def log_in(rep)
      post sales_session_url, params: { sales_session: { email: rep.email, password: "sales-pass-123" } }
      assert_redirected_to sales_dashboard_url
    end
  end
end
