# 입금 확인 서비스 (W3 F4 — PRD 7장 F4, 14장 W3 F4/F9 확정 사항).
# PAY-001: 완납 청구 재수납 차단(Payment 모델 검증 경유) / PAY-002: 취소는 이력 전이(삭제 없음)·
#          invoice 상태 재계산 / PAY-004·CR-002: 자동발행은 '완납(PAID) 전이' 시점에만
#          CashReceipt::Triggerable origin: :auto 1회 — 부분납은 보류(원장 수동 발행은 허용).
# 발행 계열 실패가 수납 성공을 롤백하지 않는다(입금 확인·발행은 별개 상태 — PAY-004).
class Payments::ConfirmService
  Result = Data.define(:success?, :payment, :invoice, :trigger) do
    def self.ok(payment, invoice, trigger = nil) = new(success?: true, payment:, invoice:, trigger:)
    def self.failure(payment, invoice = nil) = new(success?: false, payment:, invoice:, trigger: nil)

    def issue_outcome = trigger&.outcome
  end

  # 수납 등록(active) → 전액 도달 시 PAID 전이 + 자동발행 트리거 1회,
  # 미달 시 PARTIALLY_PAID(INV-005 — 잔액 유지).
  def call(invoice:, amount:, paid_on:, method:, memo: nil, confirmed_by:)
    payment = Payment.new(
      tenant: invoice&.tenant, invoice: invoice,
      amount: amount.to_i, paid_on: paid_on, method: method, memo: memo,
      status: :active, confirmed_by: confirmed_by, confirmed_at: Time.current
    )
    trigger = nil

    if invoice.nil?
      payment.errors.add(:invoice, :blank)
      return Result.failure(payment, invoice)
    end
    if invoice.CANCELLED? # INV-003: 취소 청구 수납 불가
      payment.errors.add(:invoice, :cancelled_invoice)
      return Result.failure(payment, invoice)
    end
    if invoice.DRAFT? # 초안(확정 전) 청구 수납 불가 — F4 대상은 확정 청구뿐(컨트롤러 우회 방어)
      payment.errors.add(:invoice, :draft_invoice)
      return Result.failure(payment, invoice)
    end

    begin
      ActiveRecord::Base.transaction do
        payment.save! # PAY-001: 완납 후 active 수납은 모델 검증에서 차단
        if Payment.paid_total_for(invoice) >= invoice.total_amount
          invoice.update!(status: :PAID)
          trigger = trigger_auto_issue(invoice, confirmed_by) # 완납 시에만 1회(CR-002)
        elsif !invoice.PARTIALLY_PAID?
          invoice.update!(status: :PARTIALLY_PAID) # 부분납 — 자동발행 보류(PRD 14장 확정)
        end
      end
      Result.ok(payment, invoice, trigger)
    rescue ActiveRecord::RecordInvalid
      Result.failure(payment, invoice) # 모델 검증 실패 — errors 유지(422 재렌더용)
    end
  end

  # 오체크 취소(PAY-002): cancelled 전이 + 사유·처리자 기록 후 invoice 상태 재계산.
  # 재취소·사유 누락은 거절. 연관 현금영수증 취소는 별도 경로(cash_receipts cancel — CR-005).
  def cancel(payment, reason:, cancelled_by:)
    invoice = payment.invoice
    return Result.failure(payment, invoice) unless payment.active?

    if reason.to_s.strip.blank?
      payment.errors.add(:cancel_reason, :blank)
      return Result.failure(payment, invoice)
    end

    ActiveRecord::Base.transaction do
      payment.update!(
        status: :cancelled, cancel_reason: reason.strip,
        cancelled_by: cancelled_by, cancelled_at: Time.current
      )
      recalculate_invoice_status!(invoice)
    end
    Result.ok(payment, invoice)
  rescue ActiveRecord::RecordInvalid
    Result.failure(payment, invoice)
  end

  private

  # CR-002: 완납 시점 1회 — Triggerable 결과(created/duplicate/blocked/needs_info)는 로그 기록만
  # (skip·duplicated는 무해 — CR-001 멱등이 Triggerable 내부에서 보장).
  # PAY-004: 트리거 계열 예외는 삼켜 수납 성공을 보존한다(발행은 별개 상태 — 큐에서 재시도).
  def trigger_auto_issue(invoice, confirmed_by)
    result = CashReceipt::Triggerable.trigger_issue_for(invoice, issued_by: confirmed_by, origin: :auto)
    Rails.logger.info("[Payments::ConfirmService] auto issue outcome=#{result.outcome} " \
                      "receipt_id=#{result.receipt&.id} invoice_id=#{invoice.id}")
    result
  rescue StandardError => e
    Rails.logger.warn("[Payments::ConfirmService] auto issue trigger failed " \
                      "invoice_id=#{invoice.id} error=#{e.class}: #{e.message}")
    nil
  end

  # 취소 후 상태 재계산: active 합계 기준 — 0이면 기한 경과 여부로 OVERDUE/UNPAID 복원,
  # 총액 이상이면 PAID 유지(복수 수납 중 1건 취소), 사이면 PARTIALLY_PAID(INV-005).
  # 취소 청구는 건드리지 않는다(INV-003).
  def recalculate_invoice_status!(invoice)
    return if invoice.CANCELLED?

    active_total = Payment.paid_total_for(invoice)
    next_status = if active_total >= invoice.total_amount
      :PAID
    elsif active_total.positive?
      :PARTIALLY_PAID
    elsif invoice.days_overdue.positive?
      :OVERDUE
    else
      :UNPAID
    end
    invoice.update!(status: next_status) unless invoice.status == next_status.to_s
  end
end
