# 환불 정책 분기 계산 (PRD 11.3 환불 정책 · 12장 A3).
#
# 정책 분기:
#   - service_fault      : 서비스 귀책(결제 오류·발행 불능 등) → 전액 환불
#   - user_fault_monthly : 이용자 귀책·월 결제 → 당월 내 환불 규정 문구 고지
#                          (전자상거래 법률 검토 전까지 보수적 운영 — v1.0은 금액 자동 산정 없이
#                           운영자 확정 금액 입력, 기본 0)
#   - annual_proration   : 연간(기간제) 결제 → 잔여 기간 일할 환불
#
# 본 서비스는 순수 계산기(Subscription 의존 없음) — 결제 금액·기간은 호출측에서
# subscription_events(최근 manual_payment)와 subscription.current_period_* 로 넘긴다
# ([3-S 결합 지점] 01_plan §2 가정). 실제 이체는 외부 처리 — v1.0은 기록만(A3 후속).
module Admin
  class RefundPolicyService
    BRANCHES = %i[service_fault user_fault_monthly annual_proration].freeze

    Plan = Data.define(:branch, :refund_amount, :policy_text_key, :period_days,
                       :remaining_days, :prorated_amount)

    def initialize(amount:, period_start:, period_end:, today: Date.current)
      raise ArgumentError, "amount must be >= 0" if amount.to_i.negative?

      @amount = amount.to_i
      @period_start = period_start.to_date
      @period_end = period_end.to_date
      @today = today.to_date
    end

    def preview(branch)
      branch = branch.to_sym
      raise ArgumentError, "unknown refund branch: #{branch}" unless BRANCHES.include?(branch)

      case branch
      when :service_fault      then service_fault_plan
      when :user_fault_monthly then user_fault_monthly_plan
      when :annual_proration   then annual_proration_plan
      end
    end

    private

    def period_days
      (@period_end - @period_start).to_i + 1
    end

    # 잔여 이용일 — 오늘 포함, 기간 이탈 시 0 보정
    def remaining_days
      return 0 if @today > @period_end

      ((@period_end - [ @today, @period_start ].max).to_i + 1)
    end

    def service_fault_plan
      Plan.new(branch: :service_fault, refund_amount: @amount,
               policy_text_key: "admin.refund.policies.service_fault",
               period_days: period_days, remaining_days: remaining_days,
               prorated_amount: nil)
    end

    # 보수적 운영: 자동 산정 없음 — 운영자가 규정 고지 후 확정 금액 입력(기본 0)
    def user_fault_monthly_plan
      Plan.new(branch: :user_fault_monthly, refund_amount: 0,
               policy_text_key: "admin.refund.policies.user_fault_monthly",
               period_days: period_days, remaining_days: remaining_days,
               prorated_amount: nil)
    end

    def annual_proration_plan
      prorated = @amount * remaining_days / period_days
      Plan.new(branch: :annual_proration, refund_amount: prorated,
               policy_text_key: "admin.refund.policies.annual_proration",
               period_days: period_days, remaining_days: remaining_days,
               prorated_amount: prorated)
    end
  end
end
