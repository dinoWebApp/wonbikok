# 입금 확인 (W3 F4 — PRD 7장 F4, 14장 W3 F4/F9 확정 사항).
# 모든 조회·처리는 current_tenant 스코프(TEN-001), 문구는 ko.yml(payments.* — 3-S에서 키 추가).
# 흐름: 미확인 리스트(index) → 새 입금 등록+매칭 힌트(new — PAY-003 추천 전용) →
# 체크 처리(create — Payments::ConfirmService: 전액 PAID·자동발행 트리거 / 부분 PARTIALLY_PAID) →
# 오체크 취소(cancel/cancel_payment — PAY-002 취소 이력).
class PaymentsController < ApplicationController
  before_action :set_payment, only: %i[cancel cancel_payment]

  # index·new 행 프레젠테이션 모델 — 뷰에서 쿼리 금지 원칙(잔액 계산은 컨트롤러에서 완료)
  UnpaidRow = Data.define(:invoice, :paid_total, :payments) do
    def remaining_amount = invoice.total_amount - paid_total
  end

  # 수납 이력 행 (PAY-002) — active 수납이 있는 확정 청구(완납 포함)에 취소 진입 제공
  PaymentHistoryRow = Data.define(:invoice, :payments)

  def index
    @month = sanitized_month
    @unpaid_rows = unpaid_rows(@month)
    @payment_history = payment_history_rows(@month)
  end

  def new
    @month = sanitized_month
    @hint_candidates = Payments::MatchingHintService.new(tenant: current_tenant, month: @month)
                                                     .suggest(amount: params[:hint_amount].to_i,
                                                              name: params[:hint_name].presence)
    @invoice_rows = unpaid_rows(@month)
    @payment = Payment.new(
      invoice_id: params[:invoice_id].presence,
      amount: params[:amount].presence || params[:hint_amount].presence,
      paid_on: Date.current
    )
  end

  def create
    invoice = current_tenant.invoices.find_by(id: payment_params[:invoice_id]) # TEN-001
    result = Payments::ConfirmService.new.call(
      invoice: invoice,
      amount: payment_params[:amount].to_i,
      paid_on: payment_params[:paid_on],
      method: payment_params[:method],
      memo: payment_params[:memo],
      confirmed_by: current_user.phone_number
    )

    if result.success?
      redirect_to payments_path(month: result.invoice.target_month), status: :see_other,
                  notice: t("payments.notices.confirmed", name: result.invoice.student_name_snapshot)
    else
      prepare_new_form(month: sanitized_month)
      @payment = result.payment
      flash.now[:alert] = t("errors.form")
      render :new, status: :unprocessable_entity
    end
  end

  # 오체크 취소 폼 (PAY-002 — 삭제 아닌 이력, 사유 필수)
  def cancel
  end

  def cancel_payment
    result = Payments::ConfirmService.new.cancel(
      @payment, reason: params[:cancel_reason], cancelled_by: current_user.phone_number
    )

    if result.success?
      redirect_to payments_path(month: @payment.invoice.target_month), status: :see_other,
                  notice: t("payments.notices.cancelled")
    else
      flash.now[:alert] = result.payment.errors.full_messages.first.presence ||
                          t("payments.errors.cancel_reason_blank")
      render :cancel, status: :unprocessable_entity
    end
  end

  private

  def set_payment
    @payment = Payment.for_tenant(current_tenant).find(params[:id]) # TEN-001 — 타 테넌트 404
  end

  def sanitized_month
    month = params[:month].presence || Date.current.strftime("%Y-%m")
    month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) ? month : Date.current.strftime("%Y-%m")
  end

  # 미확인(미완납) 청구 행 — 확정 청구 대상(초안 제외), 취소 청구 제외(INV-003).
  # payments는 부분납 카드의 수납 내역·취소 진입용(PAY-002).
  def unpaid_rows(month)
    invoices = current_tenant.invoices
                             .where(target_month: month,
                                    status: [ :READY, :SENT, :UNPAID, :OVERDUE, :PARTIALLY_PAID ])
                             .order(:due_on, :id)
    payments_by_invoice = active_payments_by_invoice(invoices.ids)
    invoices.filter_map do |invoice|
      payments = payments_by_invoice[invoice.id] || []
      paid_total = payments.sum(&:amount)
      next if paid_total >= invoice.total_amount

      UnpaidRow.new(invoice: invoice, paid_total: paid_total, payments: payments)
    end
  end

  # 수납 이력 행 — 대상 월 확정 청구 중 active 수납이 있는 청구(완납 포함 — PAY-002
  # 오체크 취소는 주로 완납 건에서 발생). 취소 이력은 이 화면에 표시하지 않는다.
  def payment_history_rows(month)
    invoices = current_tenant.invoices
                             .where(target_month: month,
                                    status: [ :READY, :SENT, :UNPAID, :OVERDUE, :PARTIALLY_PAID, :PAID ])
                             .order(:due_on, :id)
    payments_by_invoice = active_payments_by_invoice(invoices.ids)
    invoices.filter_map do |invoice|
      payments = payments_by_invoice[invoice.id]
      next unless payments

      PaymentHistoryRow.new(invoice: invoice, payments: payments)
    end
  end

  # active 수납을 입금일 순으로 그룹화 — 잔액·이력 계산 공용(단일 쿼리)
  def active_payments_by_invoice(invoice_ids)
    Payment.active.where(invoice_id: invoice_ids).order(:paid_on, :id).group_by(&:invoice_id)
  end

  # 422 재렌더용 폼 데이터
  def prepare_new_form(month:)
    @month = month
    @hint_candidates = []
    @invoice_rows = unpaid_rows(month)
  end

  def payment_params
    params.expect(payment: [ :invoice_id, :amount, :paid_on, :method, :memo ])
  end
end
