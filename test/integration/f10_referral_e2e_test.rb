require "test_helper"

# F10 추천 시스템 E2E 체인 테스트 (PRD 7장 F10 수용조건).
# 실제 서비스 플로우 경유: 휴대폰 인증(발송→코드 검증) → 추천 코드 가입 → 첫 결제 20% 할인 →
# 수수료 ledger 생성 → 직원 대시보드 집계 반영. 솔라피는 SIMULATED(외부 실호출 금지).
class F10ReferralE2eTest < ActionDispatch::IntegrationTest
  OWNER_PASSWORD = "owner-pass-123".freeze

  setup do
    @rep = SalesRep.create!(name: "E2E영업", email: "e2e-rep@example.com",
                            password: "sales-pass-123", role: "sales")
    @code = Referral::CodeService.issue_for!(@rep)
  end

  test "인증→추천코드→가입→첫 결제 20% 할인→ledger→대시보드 체인이 동작한다" do
    # 1. 휴대폰 인증 — 실제 서비스 플로우(발송 → 코드 검증). 코드는 고정 스텁(해시 저장·검증은 실경로).
    phone = "01087654321"
    with_fixed_verification_code("987654") do
      post registration_send_verification_url, params: { phone_number: phone }, as: :json
      assert_response :ok

      post registration_verify_url, params: { phone_number: phone, code: "987654" }, as: :json
      assert_response :ok
    end

    # 2. 추천 코드 가입 — 스냅샷 저장(REF-001), 무료체험 자동 시작(F8)
    assert_difference [ "Tenant.count", "User.count", "Subscription.count" ], 1 do
      post registration_url, params: {
        tenant: { name: "E2E 피추천 학원" },
        user: { phone_number: phone, password: OWNER_PASSWORD, password_confirmation: OWNER_PASSWORD },
        referral_code: @code
      }
    end
    assert_redirected_to onboarding_step_path(2)
    tenant = Tenant.find_by(name: "E2E 피추천 학원")
    subscription = Subscription.find_by(tenant_id: tenant.id)
    assert tenant.referred?
    assert_equal @rep.id, tenant.referred_by_sales_rep_id
    assert_equal @code, tenant.referral_code_snapshot

    # 3. 첫 결제 — 20% 할인 징수(REF-002) + manual_payment 이벤트 + ledger(REF-003)
    result = Subscriptions::PaymentService.record_manual!(subscription, amount: 30_000,
                                                          method: "transfer",
                                                          operated_by: "01011112222")

    assert result.success?
    assert result.subscription.reload.active?
    assert_equal 24_000, result.event.amount # 30,000 × 0.8
    assert_equal true, result.event.detail_hash["discount_applied"]
    assert_equal 30_000, result.event.detail_hash["original_amount"]

    ledger = CommissionLedger.sole
    assert_equal @rep.id, ledger.sales_rep_id
    assert_equal tenant.id, ledger.tenant_id
    assert_equal 24_000, ledger.base_amount # 실제 징수액 기준(REF-003)
    assert_equal 4_800, ledger.amount # 24,000 × 20%
    assert ledger.pending?
    assert_not_nil tenant.reload.first_payment_discounted_at

    # 4. 두 번째 결제 — 정상가 + 정상가 기준 ledger(REF-002 멱등)
    result = Subscriptions::PaymentService.record_manual!(result.subscription, amount: 30_000,
                                                          method: "transfer")
    assert_equal 30_000, result.event.amount
    assert_equal 2, CommissionLedger.count
    assert_equal 6_000, CommissionLedger.order(:id).last.amount

    # 5. 직원 대시보드 — 본인 스코프로 실적 반영(REF-005)
    post sales_session_url, params: { sales_session: { email: @rep.email, password: "sales-pass-123" } }
    assert_redirected_to sales_dashboard_url

    get sales_dashboard_url
    assert_response :ok
    assert_match "E2E 피추천 학원", response.body
    assert_match @code, response.body
    assert_match "54,000", response.body # 월별 결제액(첫 24,000 + 둘째 30,000)
    # 이번달 수령 예상 = 전월 기준이므로 당월 ledger는 미포함 — 연도 누적에 총 10,800(4,800+6,000)
    assert_match "10,800", response.body
  end

  test "코드 로테이션 후에도 기존 가입자 매핑은 영향받지 않는다(F10 수용조건)" do
    phone = "01087654322"
    with_fixed_verification_code("111222") do
      post registration_send_verification_url, params: { phone_number: phone }, as: :json
      post registration_verify_url, params: { phone_number: phone, code: "111222" }, as: :json
    end
    post registration_url, params: {
      tenant: { name: "로테이션후 학원" },
      user: { phone_number: phone, password: OWNER_PASSWORD, password_confirmation: OWNER_PASSWORD },
      referral_code: @code
    }
    assert_redirected_to onboarding_step_path(2)
    tenant = Tenant.find_by(name: "로테이션후 학원")
    assert_equal @rep.id, tenant.referred_by_sales_rep_id

    # 주간 로테이션 실행 — 코드 교체
    ReferralCodeRotationJob.perform_now
    assert_not_equal @code, @rep.reload.active_referral_code.code
    assert_nil Referral::CodeService.verify!(@code) # 구 코드로 신규 가입 불가(REF-001)

    # 그러나 기존 가입자의 매핑·스냅샷은 불변
    tenant.reload
    assert_equal @rep.id, tenant.referred_by_sales_rep_id
    assert_equal @code, tenant.referral_code_snapshot

    # 결제 시 수수료는 여전히 본 직원에게 발생한다
    subscription = Subscription.find_by(tenant_id: tenant.id)
    result = Subscriptions::PaymentService.record_manual!(subscription, amount: 30_000,
                                                          method: "transfer")
    assert_equal 24_000, result.event.amount
    assert_equal @rep.id, CommissionLedger.sole.sales_rep_id
  end

  test "REF-007 정지 직원의 코드로는 가입할 수 없다" do
    @rep.suspend!("부당 사용 정지") # 코드 즉시 무효화
    phone = "01087654323"
    with_fixed_verification_code("222333") do
      post registration_send_verification_url, params: { phone_number: phone }, as: :json
      post registration_verify_url, params: { phone_number: phone, code: "222333" }, as: :json
    end

    assert_no_difference "Tenant.count" do
      post registration_url, params: {
        tenant: { name: "정지코드 학원" },
        user: { phone_number: phone, password: OWNER_PASSWORD, password_confirmation: OWNER_PASSWORD },
        referral_code: @code
      }
    end
    assert_response :unprocessable_entity
  end
end
