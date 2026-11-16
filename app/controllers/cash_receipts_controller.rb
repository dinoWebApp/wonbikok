# 현금영수증 발행 이력·수동 발행·재발행·취소 (W3 F5 — 바로빌 발급대행).
# TEN-001: 모든 조회·조작은 current_tenant 스코프 경유 — 타 테넌트 리소스는 404.
class CashReceiptsController < ApplicationController
  before_action :set_cash_receipt, only: %i[show retry cancel_form cancel]
  before_action :set_month, only: :index

  def index
    @cash_receipts = current_tenant.cash_receipts
                                   .joins(:invoice)
                                   .where(invoices: { target_month: @month })
                                   .includes(invoice: :student)
                                   .order(created_at: :desc)

    # 수동 발행 대상 — 발송 완료 이후의 유효 청구 중 발행 이력 없는 건(CR-001 멱등은 트리거가 보장)
    issued_invoice_ids = @cash_receipts.map(&:invoice_id)
    @issuable_invoices = current_tenant.invoices
                                       .for_month(@month)
                                       .includes(:student)
                                       .select(&:cash_receipt_issuable?)
                                       .reject { |invoice| issued_invoice_ids.include?(invoice.id) }
  end

  def show
    @invoice = @cash_receipt.invoice
  end

  # 수동 발행 — CashReceipt::Triggerable 경유(CR-001 멱등·CR-002 트리거 검사는 트리거가 담당)
  def issue
    invoice = current_tenant.invoices.find_by(id: params[:invoice_id])
    return redirect_to cash_receipts_path, alert: t("cash_receipts.notices.invoice_not_found") if invoice.nil?

    # issued_by: 처리자 표기 — 휴대폰번호 원문 저장 금지(C4/TEN-003, 모델에서 마스킹 강제)
    result = CashReceipt::Triggerable.trigger_issue_for(invoice, issued_by: current_user.phone_number)
    redirect_after_issue(result)
  end

  # 수동 재발행 — failed·needs_info 허용(C6: needs_info는 식별번호 재확정 후 재큐)
  def retry
    unless @cash_receipt.retryable?
      return redirect_to cash_receipt_path(@cash_receipt), alert: t("cash_receipts.notices.retry_not_allowed")
    end

    if @cash_receipt.needs_info?
      @cash_receipt.resolve_identity_num! # C6: 보호자 정보 보완 확인 → pending 복귀
      unless @cash_receipt.pending?
        return redirect_to cash_receipt_path(@cash_receipt), alert: t("cash_receipts.notices.needs_info")
      end
    else
      @cash_receipt.update!(state: :pending, retry_count: @cash_receipt.retry_count + 1)
    end
    CashReceipt::IssueJob.perform_later(@cash_receipt.id)
    redirect_to cash_receipt_path(@cash_receipt), status: :see_other, notice: t("cash_receipts.notices.retry_enqueued")
  end

  # 취소 사유 폼
  def cancel_form
    redirect_to cash_receipt_path(@cash_receipt), alert: t("cash_receipts.cancel.errors.not_cancellable") unless @cash_receipt.cancellable?
  end

  # 발행 취소(issued 상태, 사유 필수 — CR-005). 실패는 422 재렌더.
  def cancel
    result = CashReceipt::CancelService.new(@cash_receipt).call(reason: params[:cancel_reason])

    if result.success?
      redirect_to cash_receipt_path(@cash_receipt), status: :see_other, notice: t("cash_receipts.notices.cancel_requested")
    else
      flash.now[:alert] = result.message
      render :cancel_form, status: :unprocessable_entity
    end
  end

  private

  # TEN-001 — 타 테넌트(또는 없는) 건은 존재 여부를 노출하지 않는다(404)
  def set_cash_receipt
    @cash_receipt = current_tenant.cash_receipts.find_by(id: params[:id])
    render file: Rails.root.join("public/404.html"), status: :not_found, layout: false if @cash_receipt.nil?
  end

  # C5: 월 파라미터는 YYYY-MM 형식 검증 기반 수용(과거 월 이력 조회 허용) —
  # 무효·공백만 당월 기본
  def set_month
    @month = params[:month].to_s.match?(/\A\d{4}-\d{2}\z/) ? params[:month] : Date.current.strftime("%Y-%m")
  end

  def redirect_after_issue(result)
    if result.receipt.nil?
      redirect_to cash_receipts_path, alert: t("cash_receipts.notices.not_issuable")
    elsif result.duplicate?
      redirect_to cash_receipt_path(result.receipt), notice: t("cash_receipts.notices.duplicate")
    elsif result.needs_info?
      redirect_to cash_receipt_path(result.receipt), alert: t("cash_receipts.notices.needs_info")
    else
      redirect_to cash_receipt_path(result.receipt), status: :see_other, notice: t("cash_receipts.notices.issue_enqueued")
    end
  end
end
