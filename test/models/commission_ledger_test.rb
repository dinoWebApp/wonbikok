require "test_helper"

# 수수료 원장 모델 테스트 (F10 — REF-004 스냅샷 불변·paid 상태 규약).
class CommissionLedgerTest < ActiveSupport::TestCase
  setup do
    @rep = SalesRep.create!(name: "원장소유자", email: "ledger-owner@example.com",
                            password: "password123", role: "sales")
    @tenant = Tenant.create!(name: "원장대상 학원", onboarding_step: 6)
  end

  test "month는 YYYY-MM 형식만 허용하고 금액·요율은 0 이상이다" do
    ledger = CommissionLedger.new(sales_rep: @rep, tenant: @tenant, month: "2026-11",
                                  base_amount: 10_000, rate: 0.20, amount: 2_000)
    assert ledger.valid?

    ledger.month = "2026/11"
    assert_not ledger.valid?

    ledger.month = "2026-11"
    ledger.base_amount = -1
    assert_not ledger.valid?
  end

  test "paid 상태는 paid_at 필수다(지급 확정 시각 기록)" do
    ledger = CommissionLedger.create!(sales_rep: @rep, tenant: @tenant, month: "2026-11",
                                      base_amount: 10_000, rate: 0.20, amount: 2_000,
                                      status: :pending)
    assert ledger.valid?

    assert_raises(ActiveRecord::RecordInvalid) { ledger.update!(status: :paid) }
    ledger.update!(status: :paid, paid_at: Time.current)
    assert ledger.valid?
    assert ledger.paid?
  end

  test "스냅샷 컬럼(base_amount·rate·amount)은 생성 후 불변 — REF-004(수정 경로 미제공은 서비스 계약)" do
    ledger = CommissionLedger.create!(sales_rep: @rep, tenant: @tenant, month: "2026-11",
                                      base_amount: 9_900, rate: 0.20, amount: 1_980)
    assert_equal 9_900, ledger.base_amount
    assert_equal BigDecimal("0.20"), ledger.rate
    assert_equal 1_980, ledger.amount
  end
end
