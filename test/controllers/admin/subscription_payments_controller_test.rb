require "test_helper"

module Admin
  class SubscriptionPaymentsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "ops@example.com", password: ADMIN_PASSWORD)
      admin_log_in(@admin)
      @tenant = Tenant.create!(name: "결제관리 학원", onboarding_step: 6)
      @subscription = Subscription.create!(tenant: @tenant, plan: "light", status: "active",
                                           trial_started_at: 40.days.ago, trial_ends_at: 10.days.ago)
    end

    # ── 결제 이력 조회·필터 ──
    test "이번 달 결제 이력을 표시한다" do
      create_event(:manual_payment, amount: 49_000, reason: "수동 결제",
                   created_at: Time.current.beginning_of_month + 2.days)

      get admin_subscription_payments_url

      assert_response :ok
      assert_match @tenant.name, response.body
      assert_match "49,000", response.body
    end

    test "이벤트 유형 필터로 결제 성공/실패를 구분한다" do
      create_event(:manual_payment, amount: 49_000,
                   created_at: Time.current.beginning_of_month + 2.days)
      create_event(:payment_failed, created_at: Time.current.beginning_of_month + 3.days)

      get admin_subscription_payments_url, params: { event_type: "manual_payment", month: Time.current.strftime("%Y-%m") }

      assert_response :ok
      assert_match "49,000", response.body

      get admin_subscription_payments_url, params: { event_type: "payment_failed", month: Time.current.strftime("%Y-%m") }

      assert_response :ok
      assert_match I18n.t("admin.subscription_payments.event_types.payment_failed"), response.body
    end

    # ── 실패 모니터링: D+30 카운트다운(산식: 최근 past_due 이벤트 + 30일) ──
    test "past_due 이용자의 데이터 삭제 예정일 카운트다운을 표시한다" do
      @subscription.update!(status: "past_due")
      create_event(:past_due, created_at: 10.days.ago)
      create_event(:payment_failed, created_at: 12.days.ago)

      get admin_subscription_payments_url

      assert_response :ok
      expected_deadline = (10.days.ago.to_date + 30)
      assert_match @tenant.name, response.body
      assert_match I18n.t("admin.subscription_payments.index.deadline",
                          date: I18n.l(expected_deadline, format: :default)), response.body
      assert_match I18n.t("admin.subscription_payments.index.days_left", days: 20), response.body
    end

    test "past_due 이벤트가 없으면 updated_at 기준으로 산정한다(근사 — 화면 산식 명시)" do
      @subscription.update!(status: "past_due")

      get admin_subscription_payments_url

      assert_response :ok
      assert_match @tenant.name, response.body
    end

    # ── 매출 집계(월별 manual_payment 합계 — MRR 근사) ──
    test "매출 집계는 manual_payment 이벤트를 월별 합산한다" do
      create_event(:manual_payment, amount: 49_000, created_at: Time.current.beginning_of_month + 1.day)
      create_event(:manual_payment, amount: 9_900, created_at: Time.current.beginning_of_month + 2.days)
      create_event(:manual_payment, amount: 99_000, created_at: 1.month.ago)
      create_event(:payment_failed, amount: nil, created_at: Time.current) # 매출 집계 제외

      get admin_subscription_payments_url

      assert_response :ok
      assert_match "58,900", response.body # 당월 합계
      assert_match "99,000", response.body # 전월 합계
    end

    # ── 환불: 정책 분기 표시(PRD 11.3) ──
    test "환불 폼은 정책 분기 3종을 표시한다" do
      create_event(:manual_payment, amount: 49_000, created_at: 2.days.ago)

      get refund_new_admin_subscription_payments_url, params: { tenant_id: @tenant.id }

      assert_response :ok
      %i[service_fault user_fault_monthly annual_proration].each do |branch|
        assert_match I18n.t("admin.refund.branches.#{branch}"), response.body
      end
      assert_match I18n.t("admin.refund.policies.user_fault_monthly"), response.body
    end

    test "환불 폼의 기본 금액은 최근 manual_payment 금액이다" do
      create_event(:manual_payment, amount: 49_000, created_at: 3.days.ago)
      create_event(:manual_payment, amount: 9_900, created_at: 1.day.ago)

      get refund_new_admin_subscription_payments_url, params: { tenant_id: @tenant.id }

      assert_response :ok
      assert_match "9,900", response.body
    end

    test "환불 확정 시 refund 이벤트·감사 로그(사유·금액·분기)가 기록된다" do
      post refund_admin_subscription_payments_url,
           params: { tenant_id: @tenant.id, branch: "service_fault", amount: 49_000,
                     reason: "발행 불능 — 서비스 귀책" }

      assert_redirected_to admin_subscription_payments_url
      event = SubscriptionEvent.find_by(subscription_id: @subscription.id, event_type: "refund")
      assert_not_nil event
      assert_equal 49_000, event.amount
      assert_equal "발행 불능 — 서비스 귀책", event.detail_hash["reason"] # f8 장부 규약 — detail JSON
      assert_equal "service_fault", event.detail_hash["branch"]
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "refund_confirmed",
                              target_type: "Tenant", target_id: @tenant.id,
                              reason: "발행 불능 — 서비스 귀책")
    end

    test "사유 없는 환불 확정은 422로 거부되고 기록이 없다(ADM-001)" do
      assert_no_difference "AuditLog.count" do
        post refund_admin_subscription_payments_url,
             params: { tenant_id: @tenant.id, branch: "service_fault", amount: 49_000, reason: "" }
      end

      assert_response :unprocessable_entity
      assert_not SubscriptionEvent.exists?(subscription_id: @subscription.id, event_type: "refund")
      assert_not AuditLog.exists?(action: "refund_confirmed", target_type: "Tenant",
                                  target_id: @tenant.id) # ADM-001 — 감사 로그 미기록
    end

    test "정책 분기 외 값은 422로 거부된다" do
      post refund_admin_subscription_payments_url,
           params: { tenant_id: @tenant.id, branch: "half_refund", amount: 49_000, reason: "사유" }

      assert_response :unprocessable_entity
    end

    test "음수 환불 금액은 422로 거부된다" do
      post refund_admin_subscription_payments_url,
           params: { tenant_id: @tenant.id, branch: "service_fault", amount: -1, reason: "사유" }

      assert_response :unprocessable_entity
    end

    test "구독이 없는 테넌트 환불 접수는 안내 후 목록으로 되돌린다" do
      orphan = Tenant.create!(name: "구독없음 학원", onboarding_step: 1)

      get refund_new_admin_subscription_payments_url, params: { tenant_id: orphan.id }

      assert_redirected_to admin_subscription_payments_url
    end

    test "미인증 접근은 차단된다" do
      delete admin_session_url

      get admin_subscription_payments_url
      assert_redirected_to new_admin_session_url
    end

    private

    def create_event(event_type, amount: nil, reason: nil, created_at: Time.current)
      SubscriptionEvent.create!(subscription: @subscription, event_type: event_type,
                                amount: amount,
                                detail: { "reason" => reason }.compact.to_json,
                                created_at: created_at)
    end

    def admin_log_in(admin_user, password: ADMIN_PASSWORD)
      post admin_session_url, params: { admin_session: { email: admin_user.email, password: password } }
      assert_response :ok
      post admin_session_otp_url, params: { otp_code: Admin::OtpService.current_code(admin_user) }
      assert_redirected_to admin_dashboard_url
    end
  end
end
