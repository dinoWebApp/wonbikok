# frozen_string_literal: true

module Subscriptions
  # 수동 결제 기록 (W4 F8 v1.0 최소형 — 정기결제 도입(P1) 전 수동 결제·파일럿 운영 대체,
  # PRD 7장 F8·11장. 실제 등록 실행은 관리자 A3 경유 — 원장 화면(subscriptions/show)은 안내만).
  # 체험(trial)·결제 유예(past_due)·일시정지(suspended)에서의 결제는 active 전이 + 기간 1개월 연장.
  # 해지(cancelled) 상태는 거절 — 재가입 경로 별도(P1).
  #
  # F10 추천 시스템 확장(2026-11-19):
  # - 피추천 테넌트 첫 유료 결제 20% 할인(REF-002 — 징수 금액 = 할인 후, 원가·할인액 detail 기록)
  # - 결제 성공 시 수수료 원장 축적(REF-003 — 실제 징수액 기준·결제 시점 요율 스냅샷)
  # - 할인·수수료 실패는 결제 성공을 롤백하지 않는다(PAY-004 패턴 준용 — 로그만).
  class PaymentService
    Result = Data.define(:success?, :subscription, :event) do
      def self.ok(subscription, event)
        new(success?: true, subscription: subscription, event: event)
      end

      def self.failure(subscription)
        new(success?: false, subscription: subscription, event: nil)
      end
    end

    def self.record_manual!(subscription, amount:, method:, memo: nil, operated_by: nil)
      new.record_manual!(subscription, amount: amount, method: method,
                                        memo: memo, operated_by: operated_by)
    end

    def record_manual!(subscription, amount:, method:, memo: nil, operated_by: nil)
      return Result.failure(subscription) if subscription.nil?
      return reject(subscription, :status, :manual_payment_not_accepted) if subscription.cancelled?
      return reject(subscription, :amount, :payment_amount_invalid) if amount.to_i <= 0
      return reject(subscription, :base, :payment_method_blank) if method.to_s.strip.blank?

      ActiveRecord::Base.transaction do
        # 결제 갱신 = 익월 경계 — 대기 중 플랜 하향이 있으면 먼저 확정(PlanChangeService 공용).
        PlanChangeService.apply_pending_downgrade_for!(subscription, force: true)
        period = next_period(subscription)
        previous_status = subscription.status

        # F10 REF-002: 피추천 테넌트 첫 유료 결제 1회 20% 할인 — 징수 금액은 할인 후.
        # 할인 적용 실패(DB 오류 등)는 결제를 롤백하지 않고 정상가로 진행(PAY-004 패턴 준용).
        discount = apply_discount_safely(subscription.tenant, amount.to_i)
        charged_amount = discount.charged_amount

        subscription.update!(status: :active, current_period_start: period.first,
                             current_period_end: period.last)
        event = subscription.subscription_events.create!(
          event_type: :manual_payment,
          amount: charged_amount,
          operated_by: operated_by,
          detail: {
            "method" => method.to_s.strip, "memo" => memo.to_s,
            "previous_status" => previous_status,
            "period_start" => period.first.to_date.iso8601,
            "period_end" => period.last.to_date.iso8601,
            "original_amount" => discount.original_amount,
            "discount_applied" => discount.applied?,
            "discount_amount" => discount.discount_amount
          }.to_json
        )
        # F10 REF-003: 수수료 원장 축적 — 할인 후 실제 징수액 기준, 결제 시점 요율 스냅샷.
        # 수수료 실패는 결제 성공을 롤백하지 않는다(로그만 — PAY-004 준용).
        accrue_commission_safely(subscription, charged_amount, event.id)
        Result.ok(subscription, event)
      end
    rescue ActiveRecord::RecordInvalid
      Result.failure(subscription)
    end

    private

    # F10 REF-002: 첫 결제 할인 — 실패 시 정상가 원금 Result(결제 계속).
    def apply_discount_safely(tenant, amount)
      Referral::DiscountService.apply_first_payment!(tenant, amount: amount)
    rescue StandardError => e
      Rails.logger.error("[PaymentService] 첫 결제 할인 실패 — tenant=#{tenant&.id} " \
                         "error=#{e.class}: #{e.message}")
      Referral::DiscountService::Result.new(applied?: false, original_amount: amount,
                                            charged_amount: amount)
    end

    # F10 REF-003: 수수료 원장 축적 — 실패는 로그만(결제·이벤트 유지).
    def accrue_commission_safely(subscription, charged_amount, event_id)
      ledger = Referral::CommissionService.accrue_on_payment!(subscription, charged_amount,
                                                              source_event: event_id)
      Rails.logger.info("[PaymentService] 수수료 원장 생성 — ledger=#{ledger&.id}") if ledger
      ledger
    rescue StandardError => e
      Rails.logger.error("[PaymentService] 수수료 원장 생성 실패 — tenant=#{subscription.tenant_id} " \
                         "error=#{e.class}: #{e.message}")
      nil
    end

    # 기간 연장 기준: 현재 기간 말이 미래면 그 일자부터(조기 납부 손실 방지), 경과했으면 즉시.
    def next_period(subscription)
      start_at = [ subscription.current_period_end, Time.current ].compact.max
      [ start_at, start_at + 1.month ]
    end

    def reject(subscription, attribute, error_key)
      subscription.errors.add(attribute, error_key)
      Result.failure(subscription)
    end
  end
end
