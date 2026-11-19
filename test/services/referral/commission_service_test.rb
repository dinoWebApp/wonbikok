require "test_helper"

# 수수료 서비스 테스트 (F10 — REF-003 캡·실제 징수액 기준 / REF-004 스냅샷 / 지급 확정 ADM-001).
class Referral::CommissionServiceTest < ActiveSupport::TestCase
  setup do
    @sales_rep = SalesRep.create!(name: "수수료직원", email: "svc-comm@example.com",
                                  password: "password123", role: "sales")
    @officer = SalesRep.create!(name: "수수료오피서", email: "svc-comm-off@example.com",
                                password: "password123", role: "officer")
    @sales_tenant = Tenant.create!(name: "sales추천 학원", onboarding_step: 6,
                                   referred_by_sales_rep: @sales_rep, created_at: 2.months.ago)
    @officer_tenant = Tenant.create!(name: "officer추천 학원", onboarding_step: 6,
                                     referred_by_sales_rep: @officer, created_at: 2.months.ago)
    @plain_tenant = Tenant.create!(name: "무관 학원", onboarding_step: 6)
    @sales_subscription = Subscription.create!(tenant: @sales_tenant, plan: :light, status: :active)
    @officer_subscription = Subscription.create!(tenant: @officer_tenant, plan: :light, status: :active)
    @plain_subscription = Subscription.create!(tenant: @plain_tenant, plan: :light, status: :active)
  end

  # ── REF-003: 실제 징수액 기준 발생 ──
  test "REF-003 결제 시점에 징수액×유효 요율로 pending ledger가 생성된다" do
    ledger = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 9_900)

    assert_not_nil ledger
    assert ledger.pending?
    assert_equal 9_900, ledger.base_amount
    assert_equal BigDecimal("0.20"), ledger.rate
    assert_equal 1_980, ledger.amount # 9900 × 20%
    assert_equal Date.current.strftime("%Y-%m"), ledger.month
  end

  test "REF-003 officer는 15% 요율로 발생한다" do
    ledger = Referral::CommissionService.accrue_on_payment!(@officer_subscription, 10_000)

    assert_equal BigDecimal("0.15"), ledger.rate
    assert_equal 1_500, ledger.amount
  end

  test "REF-003 비추천 테넌트·금액 0 이하는 ledger를 생성하지 않는다" do
    assert_nil Referral::CommissionService.accrue_on_payment!(@plain_subscription, 10_000)
    assert_nil Referral::CommissionService.accrue_on_payment!(@sales_subscription, 0)
    assert_nil Referral::CommissionService.accrue_on_payment!(nil, 10_000)
  end

  # ── REF-003: sales 12개월 캡 — 가입일 기준 결제 시점 판정 ──
  test "REF-003 sales 캡 내 결제는 발생하고 13개월째 결제는 ledger가 생성되지 않는다" do
    within_cap = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000,
                                                                at: @sales_tenant.created_at + 12.months)
    assert_not_nil within_cap # 경계일(가입+12개월) 포함

    beyond_cap = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000,
                                                                at: @sales_tenant.created_at + 13.months)
    assert_nil beyond_cap # 캡 경과 — 미생성
  end

  test "REF-003 officer는 무기한 — 13개월 이후에도 발생한다" do
    ledger = Referral::CommissionService.accrue_on_payment!(@officer_subscription, 10_000,
                                                            at: @officer_tenant.created_at + 13.months)
    assert_not_nil ledger
  end

  test "REF-003 캡은 rep의 effective_cap_months를 따른다(관리자 조정 반영)" do
    @sales_rep.update!(commission_cap_months: 1)
    assert_nil Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000,
                                                              at: @sales_tenant.created_at + 2.months)
    assert_not_nil Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000,
                                                                  at: @sales_tenant.created_at + 1.month)
  end

  # ── REF-004: 결제 시점 스냅샷 — 요율 변경 소급 없음 ──
  test "REF-004 요율 변경 후에도 기존 ledger는 불변이고 신규 결제는 신 요율이다" do
    old_ledger = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000)
    assert_equal BigDecimal("0.20"), old_ledger.rate

    @sales_rep.update!(commission_rate: 0.10) # 관리자 요율 조정

    assert_equal BigDecimal("0.20"), old_ledger.reload.rate # 기존 불변
    assert_equal 2_000, old_ledger.amount

    new_ledger = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000)
    assert_equal BigDecimal("0.10"), new_ledger.rate # 신규는 신 요율
    assert_equal 1_000, new_ledger.amount
  end

  # ── 집계 ──
  test "monthly_summary·expected_this_month·yearly_summary가 집계를 정확히 계산한다" do
    # 전월 2건(1건 지급) + 당월 1건
    Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000,
                                                   at: 1.month.ago)
    paid = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 20_000,
                                                          at: 1.month.ago)
    Referral::CommissionService.mark_paid!(paid, admin_user: nil, reason: "10월 정산 지급")
    Referral::CommissionService.accrue_on_payment!(@sales_subscription, 30_000)

    prev_month = 1.month.ago.strftime("%Y-%m")
    summary = Referral::CommissionService.monthly_summary(@sales_rep, prev_month)
    assert_equal 2, summary.count
    assert_equal 30_000, summary.base_amount
    assert_equal 6_000, summary.amount
    assert_equal 4_000, summary.paid_amount
    assert_equal 2_000, summary.pending_amount

    # 이번달 수령 예상 = 전월 확정 결제 기준(월 후불) — 지급 여부 무관 전월 합계
    assert_equal 6_000, Referral::CommissionService.expected_this_month(@sales_rep)

    yearly = Referral::CommissionService.yearly_summary(@sales_rep, Date.current.year)
    assert_equal 12_000, yearly.total_amount # 전월 6,000 + 당월 6,000
    assert_equal 4_000, yearly.paid_amount
    assert_equal 8_000, yearly.pending_amount
    assert_equal 2, yearly.rows.length
  end

  test "monthly_charged_totals는 피판매 전체 실제 결제액을 월별로 집계한다" do
    @sales_subscription.subscription_events.create!(event_type: :manual_payment, amount: 8_000,
                                                    created_at: Time.current)
    @officer_subscription.subscription_events.create!(event_type: :manual_payment, amount: 9_900,
                                                      created_at: Time.current)
    @plain_subscription.subscription_events.create!(event_type: :manual_payment, amount: 999_999,
                                                    created_at: Time.current) # 무관 테넌트

    totals = Referral::CommissionService.monthly_charged_totals(@sales_rep)
    current_month = Date.current.strftime("%Y-%m")

    assert_equal 8_000, totals[current_month] # 피판매(sales 추천)만 — officer·무관 제외
  end

  # ── 지급 확정(ADM-001) ──
  test "mark_paid!는 사유 없이는 호출 불가하고 paid 전환·감사 로그를 남긴다" do
    ledger = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000)

    assert_raises(ArgumentError) { Referral::CommissionService.mark_paid!(ledger, reason: "") }
    assert_raises(ArgumentError) { Referral::CommissionService.mark_paid!(ledger, reason: "  ") }

    admin = AdminUser.create!(email: "ledger-admin@example.com", password: "adminpass123")
    changed = Referral::CommissionService.mark_paid!(ledger, admin_user: admin,
                                                     reason: "2026-10 정산 지급 완료")
    assert changed
    assert ledger.reload.paid?
    assert_not_nil ledger.paid_at
    log = AuditLog.for_target(ledger).find_by(action: "commission_paid")
    assert_not_nil log
    assert_equal "2026-10 정산 지급 완료", log.reason
    assert_equal admin.id, log.admin_user_id
    assert_equal ledger.amount, log.detail["amount"]
  end

  test "mark_paid!는 이미 paid인 건을 재확정하지 않는다(멱등)" do
    ledger = Referral::CommissionService.accrue_on_payment!(@sales_subscription, 10_000)
    Referral::CommissionService.mark_paid!(ledger, admin_user: nil, reason: "1차 지급")
    first_paid_at = ledger.reload.paid_at

    changed = Referral::CommissionService.mark_paid!(ledger, admin_user: nil, reason: "중복 지급 시도")

    assert_not changed
    assert_equal first_paid_at, ledger.reload.paid_at
    assert_equal 1, AuditLog.where(action: "commission_paid").count
  end
end
