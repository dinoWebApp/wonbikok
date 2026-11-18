require "test_helper"

module Admin
  class TenantActionsControllerTest < ActionDispatch::IntegrationTest
    ADMIN_PASSWORD = "admin-pass-123".freeze

    setup do
      @admin = AdminUser.create!(email: "ops@example.com", password: ADMIN_PASSWORD)
      admin_log_in(@admin)
      @tenant = Tenant.create!(name: "조치대상 학원", onboarding_step: 6)
      @subscription = Subscription.create!(tenant: @tenant, plan: "light", status: "trial",
                                           trial_started_at: 10.days.ago,
                                           trial_ends_at: 20.days.from_now)
    end

    # ── ADM-001: 사유 없는 파괴적 조치는 전부 실행 불가(422 + 감사 로그 미기록) ──
    test "사유 없는 플랜 변경은 422로 거부되고 변경·기록이 없다" do
      assert_rejected_without_reason("plan_changed") { post admin_tenant_change_plan_url(@tenant), params: { plan: "standard", reason: "" } }
    end

    test "사유 없는 체험 연장은 422로 거부된다" do
      assert_rejected_without_reason("trial_extended") { post admin_tenant_extend_trial_url(@tenant), params: { days: 30, reason: "" } }
    end

    test "사유 없는 정지 기록은 422로 거부된다" do
      assert_rejected_without_reason("tenant_suspended") { post admin_tenant_suspend_url(@tenant), params: { reason: "" } }
    end

    test "사유 없는 정지 해제 기록은 422로 거부된다" do
      assert_rejected_without_reason("tenant_resumed") { post admin_tenant_resume_url(@tenant), params: { reason: "" } }
    end

    # ── 플랜 수동 변경(f8 Subscriptions::PlanChangeService.change! 경유 — 체험 중 즉시 적용) ──
    test "사유와 함께 플랜을 변경하면 구독 갱신·plan_changed 이벤트·감사 로그가 남는다" do
      post admin_tenant_change_plan_url(@tenant), params: { plan: "standard", reason: "원생 증원 요청" }

      assert_redirected_to admin_tenant_url(@tenant)
      assert_equal "standard", @subscription.reload.plan
      event = SubscriptionEvent.find_by(subscription_id: @subscription.id, event_type: "plan_changed")
      assert_not_nil event
      assert_equal "원생 증원 요청", event.detail_hash["reason"] # f8 장부 규약 — detail JSON
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "plan_changed",
                              target_type: "Tenant", target_id: @tenant.id,
                              reason: "원생 증원 요청")
    end

    test "허용 목록 외 플랜 값은 422로 거부된다(PlanChangeService :plan_unknown)" do
      post admin_tenant_change_plan_url(@tenant), params: { plan: "premium", reason: "사유" }

      assert_response :unprocessable_entity
      assert_equal "light", @subscription.reload.plan
    end

    test "동일 플랜 변경은 422로 거부된다(PlanChangeService :plan_unchanged)" do
      post admin_tenant_change_plan_url(@tenant), params: { plan: "light", reason: "사유" }

      assert_response :unprocessable_entity
    end

    # ── 체험 연장(1회 최대 30일·누적 60일 — A2) ──
    test "사유와 함께 체험을 연장하면 trial_ends_at 갱신·trial_extended 기록·감사 로그가 남는다" do
      expected_trial_ends = [ @subscription.trial_ends_at.to_date, Date.current ].max + 15

      post admin_tenant_extend_trial_url(@tenant), params: { days: 15, reason: "이전 요청" }

      assert_redirected_to admin_tenant_url(@tenant)
      assert_equal expected_trial_ends, @subscription.reload.trial_ends_at.to_date
      log = AuditLog.find_by(admin_user_id: @admin.id, action: "trial_extended", reason: "이전 요청")
      assert_not_nil log
      assert_equal 15, log.detail["days"] # json 컬럼은 레코드 파싱으로 단정(exists? 해시 비교 불가)
    end

    test "연장 일수는 1~30일만 허용한다" do
      post admin_tenant_extend_trial_url(@tenant), params: { days: 31, reason: "과다" }
      assert_response :unprocessable_entity

      post admin_tenant_extend_trial_url(@tenant), params: { days: 0, reason: "영일" }
      assert_response :unprocessable_entity
    end

    test "누적 연장이 60일을 초과하면 거부한다" do
      AuditLog.record!(admin_user: @admin, action: "trial_extended", target: @tenant,
                       reason: "1차 연장", detail: { days: 30 })

      post admin_tenant_extend_trial_url(@tenant), params: { days: 31, reason: "초과" }
      assert_response :unprocessable_entity
      assert_match I18n.t("admin.actions.errors.extension_cap", used: 30, cap: 60), response.body

      post admin_tenant_extend_trial_url(@tenant), params: { days: 30, reason: "정확히 60일" }
      assert_redirected_to admin_tenant_url(@tenant)
    end

    test "활성·해지 구독은 체험 연장 대상이 아니다" do
      @subscription.update!(status: "active")

      post admin_tenant_extend_trial_url(@tenant), params: { days: 15, reason: "사유" }

      assert_response :unprocessable_entity
    end

    test "구독 레코드가 없는 테넌트 조치는 422로 안내된다" do
      tenant_without_subscription = Tenant.create!(name: "구독없음 학원", onboarding_step: 1)

      post admin_tenant_change_plan_url(tenant_without_subscription), params: { plan: "light", reason: "사유" }

      assert_response :unprocessable_entity
    end

    # ── 정지/해제(v1.0 이력 기록만 — 실차단 후속) ──
    test "정지 기록은 감사 로그·suspended 이벤트를 남기고 상세에 정지 표시가 나타난다" do
      post admin_tenant_suspend_url(@tenant), params: { reason: "결제 장기 미납" }

      assert_redirected_to admin_tenant_url(@tenant)
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "tenant_suspended",
                              target_type: "Tenant", target_id: @tenant.id, reason: "결제 장기 미납")
      assert SubscriptionEvent.exists?(subscription_id: @subscription.id, event_type: "suspended")

      get admin_tenant_url(@tenant)
      assert_match I18n.t("admin.tenants.show.suspension_recorded"), response.body
    end

    test "해제 기록은 감사 로그를 남긴다" do
      AuditLog.record!(admin_user: @admin, action: "tenant_suspended", target: @tenant, reason: "정지")

      post admin_tenant_resume_url(@tenant), params: { reason: "미납 해소" }

      assert_redirected_to admin_tenant_url(@tenant)
      assert AuditLog.exists?(admin_user_id: @admin.id, action: "tenant_resumed",
                              target_type: "Tenant", target_id: @tenant.id, reason: "미납 해소")
    end

    test "미인증 조치 시도는 차단된다" do
      delete admin_session_url

      post admin_tenant_suspend_url(@tenant), params: { reason: "사유" }
      assert_redirected_to new_admin_session_url
      assert_not AuditLog.exists?(action: "tenant_suspended", target_id: @tenant.id)
    end

    private

    def assert_rejected_without_reason(audit_action)
      assert_no_difference "AuditLog.count" do
        yield
      end
      assert_response :unprocessable_entity
      assert_match I18n.t("admin.actions.errors.reason_required"), response.body
      assert_equal "trial", @subscription.reload.status # 상태 불변
      assert_not AuditLog.exists?(action: audit_action, target_type: "Tenant",
                                  target_id: @tenant.id) # ADM-001 — 조치 감사 미기록
    end

    def admin_log_in(admin_user, password: ADMIN_PASSWORD)
      post admin_session_url, params: { admin_session: { email: admin_user.email, password: password } }
      assert_response :ok
      post admin_session_otp_url, params: { otp_code: Admin::OtpService.current_code(admin_user) }
      assert_redirected_to admin_dashboard_url
    end
  end
end
