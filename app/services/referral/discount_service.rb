# frozen_string_literal: true

module Referral
  # 첫 결제 20% 할인 (F10 — REF-002: 피추천 테넌트당 정확히 1회·멱등).
  #
  # 멱등은 DB 원자 갱신으로 보장한다: first_payment_discounted_at이 nil인 행만 UPDATE가 성공하며
  # (UPDATE ... WHERE first_payment_discounted_at IS NULL — 변경 행 1 = 이 호출이 적용권 획득),
  # 동시 결제 경쟁에서도 정확히 한 호출만 할인을 적용한다. 타임스탬프는 tenants 컬럼에 기록.
  #
  # 원가·할인액의 장부 기록은 호출측(Subscriptions::PaymentService — manual_payment 이벤트 detail)이
  # 본 서비스의 Result를 받아 수행한다(SUB-005 금액 정합).
  class DiscountService
    DISCOUNT_RATE = BigDecimal("0.20") # 첫 결제 20% 할인 — 이후 정상가

    Result = Data.define(:applied?, :original_amount, :charged_amount) do
      def discount_amount
        original_amount - charged_amount
      end
    end

    class << self
      # 피추천 테넌트의 첫 유료 결제에 한해 20% 할인 후 금액 반환.
      # 비추천 테넌트·이미 할인된 테넌트는 원금 그대로(applied? false) — 재결제·환불 재결제 미적용.
      def apply_first_payment!(tenant, amount:)
        original = amount.to_i
        eligible = tenant.is_a?(Tenant) && tenant.referred? && original.positive?
        claimed = eligible ? claim!(tenant) : false
        build_result(original, claimed: claimed)
      end

      private

      # 적용권 획득(원자) — true면 이 호출이 유일 적용(REF-002 멱등 보장).
      def claim!(tenant)
        Tenant.where(id: tenant.id, first_payment_discounted_at: nil)
              .update_all(first_payment_discounted_at: Time.current) == 1 # rubocop:disable Rails/SkipsModelValidations
      end

      def build_result(original, claimed:)
        charged = claimed ? (original * (1 - DISCOUNT_RATE)).round : original
        Result.new(applied?: claimed, original_amount: original, charged_amount: charged)
      end
    end
  end
end
