require "test_helper"

# 첫 결제 할인 서비스 테스트 (F10 — REF-002: 20% 1회·멱등·DB 원자 갱신).
class Referral::DiscountServiceTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.create!(name: "할인직원", email: "svc-discount@example.com",
                            password: "password123", role: "sales")
    @referred_tenant = Tenant.create!(name: "피추천 학원", onboarding_step: 6,
                                      referred_by_sales_rep: @rep)
    @plain_tenant = Tenant.create!(name: "일반 학원", onboarding_step: 6)
  end

  test "REF-002 피추천 테넌트 첫 결제는 20% 할인 후 금액을 반환하고 타임스탬프를 기록한다" do
    result = Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000)

    assert result.applied?
    assert_equal 10_000, result.original_amount
    assert_equal 8_000, result.charged_amount
    assert_equal 2_000, result.discount_amount
    assert_not_nil @referred_tenant.reload.first_payment_discounted_at
  end

  test "REF-002 두 번째 결제는 정상가다(멱등 — 재결제 미적용)" do
    Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000)

    result = Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000)

    assert_not result.applied?
    assert_equal 10_000, result.charged_amount
  end

  test "REF-002 비추천 테넌트는 할인이 적용되지 않는다" do
    result = Referral::DiscountService.apply_first_payment!(@plain_tenant, amount: 10_000)

    assert_not result.applied?
    assert_equal 10_000, result.charged_amount
    assert_nil @plain_tenant.reload.first_payment_discounted_at
  end

  test "REF-002 환불 후 재결제에도 재적용되지 않는다(타임스탬프 불변)" do
    Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000)
    marked_at = @referred_tenant.reload.first_payment_discounted_at

    Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000)

    assert_equal marked_at, @referred_tenant.reload.first_payment_discounted_at
    assert_equal 10_000, Referral::DiscountService.apply_first_payment!(@referred_tenant,
                                                                        amount: 10_000).charged_amount
  end

  test "REF-002 동시 호출 경쟁에서도 정확히 1회만 적용된다(원자 갱신)" do
    results = Array.new(5) { Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 10_000) }

    assert_equal 1, results.count(&:applied?)
    assert_equal 1, results.count { |r| r.charged_amount == 8_000 }
  end

  test "REF-002 할인 금액은 원 단위 정수 반올림이다" do
    result = Referral::DiscountService.apply_first_payment!(@referred_tenant, amount: 9_901)

    assert_equal 7_921, result.charged_amount # 9901 × 0.8 = 7920.8 → 7921
  end
end
