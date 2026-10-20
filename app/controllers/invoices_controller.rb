# 월간 청구 & 납부 안내 (W2 F3).
# 모든 조회는 current_tenant 스코프(TEN-001). 문구는 ko.yml.
# 흐름: 생성(Generator) → 미리보기·확정(DRAFT→READY, INV-006) → 개별 조정(READY 이후 사유 필수,
# INV-002) → 발송(즉시/예약, Dispatcher) → 결과(성공/실패·다시 보내기, MSG-001/007).
class InvoicesController < ApplicationController
  before_action :set_invoice, only: %i[edit update cancel resend]
  before_action :set_month, only: %i[index confirm results send_batch cancel_queue]

  def index
    @invoices = current_tenant.invoices.for_month(@month).includes(student: :guardians).order(:id)
    @summary = invoice_summary(@invoices)
    # INV-006 미리보기: 생성 전 대상(재원 원생) 대비 미생성 인원 안내
    @pending_students = current_tenant.students.active.order(:id) - @invoices.map(&:student)
  end

  # 이번 달 청구 만들기(수동 트리거 — 배치와 동일 Generator, 멱등)
  def create
    target_month = params[:target_month].to_s
    target_month = Date.current.strftime("%Y-%m") unless target_month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
    result = Invoices::Generator.new(tenant: current_tenant,
                                     target_month:).call
    redirect_to invoices_path(month: result.target_month), status: :see_other,
               notice: t("invoices.notices.generated",
                         created: result.created, skipped: result.skipped,
                         month: result.target_month)
  end

  # 미리보기 확정: DRAFT → READY (INV-006)
  def confirm
    invoices = current_tenant.invoices.for_month(@month).DRAFT
    count = 0
    invoices.find_each { |invoice| count += 1 if invoice.confirm! }
    redirect_to invoices_path(month: @month), status: :see_other,
                notice: t("invoices.notices.confirmed", count:)
  end

  # 발송: READY 대상 선택 · 즉시/예약 (MSG-007)
  def send_batch
    invoices = current_tenant.invoices.where(id: params[:invoice_ids], status: :READY)
    send_at = parse_send_at
    if params[:scheduled].present? && send_at.blank?
      # MSG-007: 예약 시각 파싱 실패 시 즉시 발송으로 변질되지 않게 차단
      redirect_to invoices_path(month: @month),
                  alert: t("invoices.errors.invalid_send_at"), status: :see_other
      return
    end

    result = Notifications::Dispatcher.new(tenant: current_tenant)
                                      .dispatch(invoices, send_at:)
    # 9.1 정합: 실제 큐에 등록된 건만 SENT 전이(수신처 없는 건은 SENT 표기 금지).
    # 즉시 발송만 선전이 — 예약발송은 MessageSendJob 완료 시 mark_sent!.
    if send_at.blank?
      current_tenant.invoices.where(id: result.dispatched_invoice_ids)
                    .find_each { |invoice| invoice.mark_sent! }
    end

    redirect_to results_invoices_path(month: @month), status: :see_other,
                notice: t("invoices.notices.dispatched",
                          queued: result.queued, duplicated: result.duplicated,
                          missing: result.recipients_missing, scheduled: send_at.present?,
                          ids: result.dispatched_invoice_ids.size)
  end

  # 발송 결과: 성공/실패/사유 + 대기열(예약) 표시 (9.3, MSG-007)
  def results
    @logs = current_tenant.message_logs
                          .joins(:invoice)
                          .where(invoices: { target_month: @month })
                          .includes(invoice: :student)
                          .order(created_at: :desc)
  end

  def edit
    # INV-006: 발송 전까지 수정 가능 — SENT 이후·취소 청구는 수정 화면 진입 차단
    unless @invoice.DRAFT? || @invoice.READY?
      redirect_to invoices_path(month: @invoice.target_month),
                  alert: t("invoices.errors.not_editable"), status: :see_other
      return
    end
    @needs_change_reason = !@invoice.DRAFT? # INV-002
  end

  def update
    if @invoice.adjust!(
      adjustment_amount: invoice_params[:adjustment_amount],
      adjustment_note: invoice_params[:adjustment_note],
      change_reason: invoice_params[:change_reason]
    )
      redirect_to invoices_path(month: @invoice.target_month), status: :see_other,
                  notice: t("invoices.notices.updated")
    else
      @needs_change_reason = !@invoice.DRAFT?
      render :edit, status: :unprocessable_entity
    end
  end

  # 청구 취소 (INV-003) — GET: 사유 폼, POST: 취소 처리(사유 필수)
  def cancel
    return render :cancel if request.get? || request.head?

    if @invoice.cancel!(params[:cancel_reason])
      redirect_to invoices_path(month: @invoice.target_month), status: :see_other,
                  notice: t("invoices.notices.cancelled")
    else
      flash.now[:alert] = @invoice.errors.full_messages.first.presence ||
                                  t("invoices.errors.cancel_reason_blank")
      render :cancel, status: :unprocessable_entity
    end
  end

  # 다시 보내기 (MSG-001 예외 — resend_of 이력 연결). 9.1: SENT/UNPAID/OVERDUE만 허용.
  def resend
    unless @invoice.status.in?([ :SENT, :UNPAID, :OVERDUE ])
      redirect_to results_invoices_path(month: @invoice.target_month),
                  alert: t("invoices.errors.resend_not_allowed"), status: :see_other
      return
    end

    original = current_tenant.message_logs
                             .where(invoice_id: @invoice.id, template_type: :invoice_notice)
                             .order(:created_at).last
    result = Notifications::Dispatcher.new(tenant: current_tenant)
                                      .dispatch(Invoice.where(id: @invoice.id),
                                                resend: original)
    if result.queued.positive?
      redirect_to results_invoices_path(month: @invoice.target_month), status: :see_other,
                  notice: t("invoices.notices.resent")
    else
      redirect_to results_invoices_path(month: @invoice.target_month),
                  alert: t("invoices.errors.resend_failed")
    end
  end

  # 예약 발송 취소 (MSG-007)
  def cancel_queue
    log = current_tenant.message_logs.find(params[:message_log_id])
    if Notifications::Dispatcher.new(tenant: current_tenant).cancel_scheduled(log)
      redirect_to results_invoices_path(month: @month), status: :see_other,
                  notice: t("invoices.notices.queue_cancelled")
    else
      redirect_to results_invoices_path(month: @month),
                  alert: t("invoices.errors.queue_cancel_failed")
    end
  end

  private

  def set_invoice
    @invoice = current_tenant.invoices.find(params[:id]) # TEN-001
  end

  def set_month
    month = params[:month].presence || Date.current.strftime("%Y-%m")
    @month = month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/) ? month : Date.current.strftime("%Y-%m")
  end

  def parse_send_at
    return nil if params[:scheduled].blank? || params[:send_at].blank?

    Time.zone.parse(params[:send_at])
  end

  def invoice_params
    params.expect(invoice: [ :adjustment_amount, :adjustment_note, :change_reason ])
  end

  def invoice_summary(invoices)
    billable = invoices.select { |i| !i.CANCELLED? }
    {
      total_amount: billable.sum(&:total_amount),
      count: billable.size,
      draft_count: invoices.count(&:DRAFT?),
      ready_count: invoices.count(&:READY?),
      sent_count: invoices.count(&:SENT?),
      cancelled_count: invoices.count(&:CANCELLED?)
    }
  end
end
