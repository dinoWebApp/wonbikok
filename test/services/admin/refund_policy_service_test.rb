require "test_helper"

module Admin
  class RefundPolicyServiceTest < ActiveSupport::TestCase
    # 2026-01-01~01-31(31일 기간), 기준일 01-16 → 잔여 16일
    def service(amount: 300_000, branch: :service_fault,
                period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 1, 31),
                today: Date.new(2026, 1, 16))
      Admin::RefundPolicyService.new(amount: amount, period_start: period_start,
                                     period_end: period_end, today: today).preview(branch)
    end

    test "서비스 귀책은 전액 환불이다(PRD 11.3)" do
      plan = service(branch: :service_fault)

      assert_equal 300_000, plan.refund_amount
      assert_equal :service_fault, plan.branch
      assert_equal "admin.refund.policies.service_fault", plan.policy_text_key
    end

    test "이용자 귀책·월 결제는 자동 산정 없이 규정 문구 고지(보수적 운영)" do
      plan = service(branch: :user_fault_monthly)

      assert_equal 0, plan.refund_amount
      assert_equal "admin.refund.policies.user_fault_monthly", plan.policy_text_key
    end

    test "연간(기간제) 결제는 잔여 기간 일할 환불이다" do
      plan = service(branch: :annual_proration)

      # 300_000 * 16/31 = 154_838.7... → 정수 절삭 154_838
      assert_equal 154_838, plan.refund_amount
      assert_equal 31, plan.period_days
      assert_equal 16, plan.remaining_days
    end

    test "기준일이 기간을 벗어나면 잔여 0일로 일할액 0원이다" do
      plan = service(branch: :annual_proration, today: Date.new(2026, 2, 5))

      assert_equal 0, plan.remaining_days
      assert_equal 0, plan.refund_amount
    end

    test "기준일이 기간 시작 전이면 전체 기간 기준으로 계산한다" do
      plan = service(branch: :annual_proration, today: Date.new(2025, 12, 20))

      assert_equal 31, plan.remaining_days
      assert_equal 300_000, plan.refund_amount
    end

    test "정의되지 않은 분기는 ArgumentError다" do
      assert_raise(ArgumentError) { service(branch: :half_refund) }
    end

    test "음수 결제 금액은 ArgumentError다" do
      assert_raise(ArgumentError) do
        Admin::RefundPolicyService.new(amount: -1, period_start: Date.new(2026, 1, 1),
                                       period_end: Date.new(2026, 1, 31))
      end
    end

    test "BRANCHES는 정책 3종을 고정한다(PRD 11.3 분기)" do
      assert_equal %i[service_fault user_fault_monthly annual_proration],
                   Admin::RefundPolicyService::BRANCHES
    end
  end
end
