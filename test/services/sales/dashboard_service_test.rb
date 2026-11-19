require "test_helper"

# 영업 직원 대시보드 서비스 테스트 (F10 — REF-005 스코프 격리: 본인 데이터만).
class Sales::DashboardServiceTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.create!(name: "대시보드직원", email: "svc-dash@example.com",
                            password: "password123", role: "sales", title: "영업 이사")
    @other = SalesRep.create!(name: "타직원", email: "svc-dash-other@example.com",
                              password: "password123", role: "sales")
    @my_tenant = Tenant.create!(name: "내추천 학원", onboarding_step: 6,
                                referred_by_sales_rep: @rep, created_at: 3.months.ago)
    @other_tenant = Tenant.create!(name: "타직원추천 학원", onboarding_step: 6,
                                   referred_by_sales_rep: @other, created_at: 3.months.ago)
    @subscription = Subscription.create!(tenant: @my_tenant, plan: :light, status: :active,
                                         current_period_start: 1.day.ago,
                                         current_period_end: 1.month.from_now)
    @service = Sales::DashboardService.new(@rep)
  end

  test "REF-005 피판매 목록은 본인 추천 테넌트만이고 개인정보는 미수집이다" do
    rows = @service.tenant_rows

    assert_equal 1, rows.length
    row = rows.first
    assert_equal "내추천 학원", row.tenant_name
    assert_equal "light", row.plan
    assert_equal "active", row.status
    assert_equal @my_tenant.created_at.to_date, row.joined_on
    # TenantRow는 원장 개인정보(원장명·전화) 필드 자체가 없다 — 구조적 마스킹(TEN 준용)
    assert !row.respond_to?(:owner_phone)
    assert !row.respond_to?(:owner_name)
  end

  test "REF-005 월별 결제액은 본인 피판매 결제만 집계된다(타 직원 제외)" do
    @subscription.subscription_events.create!(event_type: :manual_payment, amount: 8_000)
    Subscription.create!(tenant: @other_tenant, plan: :light, status: :active)
      .subscription_events.create!(event_type: :manual_payment, amount: 500_000)

    year = Date.current.year
    rows = @service.monthly_charged_rows(year)
    month = Date.current.strftime("%Y-%m")
    row = rows.find { |r| r.month == month }

    assert_equal 8_000, row.total_amount
    assert_equal 12, rows.length # 연도 12개월 행 완성
  end

  test "이번달 수령 예상·연도 누적은 CommissionService 위임이며 본인 스코프다" do
    Referral::CommissionService.accrue_on_payment!(@subscription, 8_000, at: 1.month.ago)

    assert_equal 1_600, @service.expected_this_month # 전월 8,000 × 20%

    yearly = @service.yearly_summary(Date.current.year)
    assert_equal 1_600, yearly.total_amount
    assert_equal 0, yearly.paid_amount
    assert_equal 1_600, yearly.pending_amount
  end

  test "active_code는 본인 유효 코드만 반환한다" do
    assert_nil @service.active_code # 발급 전
    code = Referral::CodeService.issue_for!(@rep)
    assert_equal code, @service.active_code.code
  end
end
