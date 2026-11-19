require "test_helper"

module Admin
  # 영업 직원 관리 컨트롤러 테스트 (F10 — A2 확장: CRUD·role 기본값·정지 사유 ADM-001·지급 확정).
  class SalesStaffsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "sales-staff-admin@example.com", password: ADMIN_PASSWORD)
      admin_log_in(@admin)
      @staff = SalesRep.create!(name: "관리대상직원", email: "managed-rep@example.com",
                                password: "password123", role: "sales")
    end

    test "목록·상세가 직원 정보와 수수료 요약을 표시한다" do
      get admin_sales_staffs_url
      assert_response :ok
      assert_match "관리대상직원", response.body

      get admin_sales_staff_url(@staff)
      assert_response :ok
      assert_match "관리대상직원", response.body
    end

    test "생성 시 role·기본 요율이 적용되고 첫 추천 코드가 발급된다" do
      assert_difference "SalesRep.count", 1 do
        post admin_sales_staffs_url, params: {
          sales_rep: { name: "신규영업", email: "new-rep@example.com", password: "password123",
                       password_confirmation: "password123", role: "sales", title: "영업 이사" }
        }
      end

      rep = SalesRep.find_by(email: "new-rep@example.com")
      assert rep.active?
      assert_equal BigDecimal("0.20"), rep.effective_commission_rate # role 기본값
      assert_equal 12, rep.effective_cap_months
      assert_not_nil rep.active_referral_code # 첫 코드 즉시 발급
      assert AuditLog.for_target(rep).where(action: "sales_staff_created").exists?
    end

    test "officer 생성 시 15%·무기한 기본값이 적용된다" do
      post admin_sales_staffs_url, params: {
        sales_rep: { name: "오피서", email: "new-officer@example.com", password: "password123",
                     password_confirmation: "password123", role: "officer" }
      }

      rep = SalesRep.find_by(email: "new-officer@example.com")
      assert_equal BigDecimal("0.15"), rep.effective_commission_rate
      assert_nil rep.effective_cap_months
    end

    test "요율 0.05~0.30 범위 밖 생성은 422로 거절된다" do
      assert_no_difference "SalesRep.count" do
        post admin_sales_staffs_url, params: {
          sales_rep: { name: "범위위반", email: "rate-bad@example.com", password: "password123",
                       password_confirmation: "password123", role: "sales", commission_rate: "0.50" }
        }
      end
      assert_response :unprocessable_entity
    end

    test "수정으로 role·요율·캡을 변경할 수 있고 빈 비밀번호는 유지된다" do
      original_digest = @staff.password_digest
      patch admin_sales_staff_url(@staff), params: {
        sales_rep: { name: "수정된직원", email: @staff.email, role: "officer",
                     title: "CRO", commission_rate: "0.25", commission_cap_months: "",
                     password: "", password_confirmation: "" }
      }

      assert_redirected_to admin_sales_staff_url(@staff)
      @staff.reload
      assert_equal "officer", @staff.role
      assert_equal BigDecimal("0.25"), @staff.commission_rate
      assert_equal "CRO", @staff.title
      assert_equal original_digest, @staff.password_digest # 빈 비밀번호 = 기존 유지
    end

    # REF-007·ADM-001: 정지는 사유 필수 + 코드 무효화
    test "사유 없는 정지는 422로 거부되고 상태가 유지된다" do
      Referral::CodeService.issue_for!(@staff)
      post suspend_admin_sales_staff_url(@staff), params: { reason: "" }

      assert_response :unprocessable_entity
      assert @staff.reload.active?
    end

    test "사유와 함께 정지하면 코드가 무효화되고 감사 로그가 남는다" do
      code = Referral::CodeService.issue_for!(@staff)

      post suspend_admin_sales_staff_url(@staff), params: { reason: "부당 사용" }

      assert_redirected_to admin_sales_staff_url(@staff)
      assert @staff.reload.suspended?
      assert_nil Referral::CodeService.verify!(code) # 코드 즉시 무효화(REF-007)
      log = AuditLog.for_target(@staff).find_by(action: "sales_rep_suspended")
      assert_equal "부당 사용", log&.reason
    end

    test "정지 해제도 사유 필수다" do
      @staff.suspend!("정지 사유")
      post resume_admin_sales_staff_url(@staff), params: { reason: "" }
      assert_response :unprocessable_entity

      post resume_admin_sales_staff_url(@staff), params: { reason: "징계 해제" }
      assert_redirected_to admin_sales_staff_url(@staff)
      assert @staff.reload.active?
    end

    test "지급 확정은 사유 필수이며 확정 시 감사 로그가 남는다" do
      tenant = Tenant.create!(name: "지급대상 학원", onboarding_step: 6,
                              referred_by_sales_rep: @staff)
      subscription = Subscription.create!(tenant: tenant, plan: :light, status: :active)
      ledger = Referral::CommissionService.accrue_on_payment!(subscription, 10_000)

      post mark_paid_admin_sales_staff_url(@staff, ledger_id: ledger.id), params: { reason: "" }
      assert_response :unprocessable_entity
      assert ledger.reload.pending?

      post mark_paid_admin_sales_staff_url(@staff, ledger_id: ledger.id), params: { reason: "10월 정산" }
      assert_redirected_to admin_sales_staff_url(@staff)
      assert ledger.reload.paid?
      assert AuditLog.for_target(ledger).where(action: "commission_paid").exists?
    end

    test "이미 지급된 건의 재확정은 안내와 함께 무시된다" do
      tenant = Tenant.create!(name: "중복지급 학원", onboarding_step: 6,
                              referred_by_sales_rep: @staff)
      subscription = Subscription.create!(tenant: tenant, plan: :light, status: :active)
      ledger = Referral::CommissionService.accrue_on_payment!(subscription, 10_000)
      Referral::CommissionService.mark_paid!(ledger, admin_user: @admin, reason: "1차")

      post mark_paid_admin_sales_staff_url(@staff, ledger_id: ledger.id), params: { reason: "재시도" }
      assert_redirected_to admin_sales_staff_url(@staff)
      assert_equal 1, AuditLog.for_target(ledger).where(action: "commission_paid").count
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
