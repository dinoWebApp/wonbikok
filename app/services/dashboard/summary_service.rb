# frozen_string_literal: true

# 마감 대시보드·리포트 집계 서비스 (W4 F7 — PRD 7장 F7).
# 뷰에서 DB 직접 쿼리 금지 원칙에 따라 대시보드(show)·마감 리포트(report)의
# 모든 집계를 이 서비스가 전담한다. 읽기 전용 — 어떤 상태도 변경하지 않는다.
#
# 정산 기준 (F7 수용조건 "리포트 수치는 발행 이력과 정합" — 기준 라벨을 화면에 병기):
# - 청구액: 당월 billable(취소 제외 — INV-003) 합계. DRAFT 포함(초안 건수는 draft_count로 별도 제공).
# - 수납액: 당월 billable 청구의 active 수납 합계(취소 이력 제외 — PAY-002).
# - 미납액: 청구액 - 수납액(음수는 0 — 미달 계산 오차를 미납으로 표시하지 않는다).
# - 미확인 입금: 미완납 확정 청구 수 — PaymentsController#unpaid_rows와 동일 기준
#   (초안·취소·완납 제외, 잔액 0 초과 — 링크 대상 화면과 수가 일치해야 한다).
# - 발행 실패: 당월 청구의 현금영수증 state=failed 건수.
# - 미발행 잔여: PAID 청구 중 issued 영수증이 없는 청구(CR-001: 발행 확정은 issued만 인정 —
#   needs_info·failed·cancelled 보유 건도 미발행으로 본다).
#
# TEN-001: 모든 질의는 tenant 연관 경유 — 타 테넌트 데이터가 결과에 포함되지 않는다.
class Dashboard::SummaryService
  # 다가오는 리마인더 행(읽기 전용 스냅샷 — 뷰에서 AR 객체를 조작하지 않는다)
  UpcomingReminder = Data.define(:invoice_id, :student_name, :due_on, :days_overdue, :stage)
  # 미납 명단 행(마감 리포트용 — 원생명·금액)
  UnpaidEntry = Data.define(:invoice_id, :student_name, :total_amount, :paid_amount, :balance)
  # 미발행 잔여 행(경고 배너용 — 원생명·금액)
  UnissuedEntry = Data.define(:invoice_id, :student_name, :total_amount)

  Result = Data.define(
    :month, :students_count, :invoice_count, :draft_count,
    :billed_amount, :billed_basis, :paid_amount, :paid_basis,
    :unpaid_amount, :payment_rate,
    :unconfirmed_payments_count, :failed_receipts_count,
    :upcoming_reminders, :upcoming_reminders_count,
    :unissued_students, :month_end_near?, :month_elapsed?,
    :closing_complete?, :empty_state,
    :unpaid_list, :receipt_state_counts
  )

  # 기준 라벨 식별자 — 문구는 뷰가 t() 키로 변환한다(코드 하드코딩 금지).
  BILLED_BASIS = :billable_excluding_cancelled # 확정 청구 합계 · 취소 제외
  PAID_BASIS = :actual_payment_records         # 실수납 기록 합계

  # 오늘 할 일 — 다가오는 리마인더 상위 노출 수(기한 임박 순, 나머지는 건수만)
  UPCOMING_REMINDER_LIMIT = 5
  # 미발행 잔여 월말 강조 — 말일 7일 이내("가산세 방지" 문구 플래그)
  MONTH_END_NOTICE_DAYS = 7

  # 미확인 입금 집계 기준 — PaymentsController#unpaid_rows와 동일(확정 청구 5종).
  UNCONFIRMED_STATUSES = %w[READY SENT UNPAID OVERDUE PARTIALLY_PAID].freeze

  def call(tenant:, month:, on: Date.current)
    invoices = tenant.invoices.for_month(month).order(:id).to_a
    billable = invoices.reject(&:CANCELLED?) # INV-003: 취소 청구는 수납 합계·정산에서 제외
    paid_totals = Payment.for_tenant(tenant).active
                         .where(invoice_id: billable.map(&:id))
                         .group(:invoice_id).sum(:amount)

    billed_amount = billable.sum(&:total_amount)
    paid_amount = paid_totals.values.sum
    unpaid_amount = [ billed_amount - paid_amount, 0 ].max
    payment_rate = billed_amount.positive? ? (paid_amount * 100.0 / billed_amount).round : nil

    month_end = month_end_date_for(month)
    month_elapsed = month_end < on
    month_end_near = (month_end - on).to_i <= MONTH_END_NOTICE_DAYS

    students_count = tenant.students.count
    empty_state = if students_count.zero?
      :no_students
    elsif invoices.empty?
      :no_invoices
    end

    Result.new(
      month: month,
      students_count: students_count,
      invoice_count: invoices.size,
      draft_count: invoices.count(&:DRAFT?),
      billed_amount: billed_amount,
      billed_basis: BILLED_BASIS,
      paid_amount: paid_amount,
      paid_basis: PAID_BASIS,
      unpaid_amount: unpaid_amount,
      payment_rate: payment_rate,
      unconfirmed_payments_count: unconfirmed_count(billable, paid_totals),
      failed_receipts_count: failed_receipts_count(tenant, month),
      upcoming_reminders: upcoming_reminders(tenant, on),
      upcoming_reminders_count: tenant.invoices.remindable.count,
      unissued_students: unissued_entries(tenant, billable),
      month_end_near?: month_end_near,
      month_elapsed?: month_elapsed,
      closing_complete?: month_elapsed || (billed_amount.positive? && unpaid_amount.zero?),
      empty_state: empty_state,
      unpaid_list: unpaid_entries(billable, paid_totals),
      receipt_state_counts: receipt_state_counts(tenant, month)
    )
  end

  private

  # 미확인 입금 — 미완납 확정 청구(초안·취소·완납 제외, 잔액 0 초과).
  # payments#index의 unpaid_rows와 동일 기준으로 수를 맞춘다(눌렀을 때 화면과 일치).
  def unconfirmed_count(billable, paid_totals)
    billable.count do |invoice|
      invoice.status.in?(UNCONFIRMED_STATUSES) &&
        paid_totals.fetch(invoice.id, 0) < invoice.total_amount
    end
  end

  def failed_receipts_count(tenant, month)
    tenant.cash_receipts.failed.joins(:invoice)
          .where(invoices: { target_month: month }).count
  end

  # 다가오는 리마인더 — F6 기존 remindable 스코프 재사용(MSG-004 제외 원생 배제 포함),
  # 기한 임박(오래된 기한) 순 상위만 스냅샷으로 제공. stage는 발송 단계 도래 여부(nil 허용).
  def upcoming_reminders(tenant, on)
    tenant.invoices.remindable.to_a
          .sort_by { |invoice| [ invoice.due_on, invoice.id ] }
          .first(UPCOMING_REMINDER_LIMIT)
          .map do |invoice|
            UpcomingReminder.new(
              invoice_id: invoice.id,
              student_name: invoice.student_name_snapshot,
              due_on: invoice.due_on,
              days_overdue: invoice.days_overdue(on: on),
              stage: Reminders::Scheduler.due_stage_for(invoice, date: on)
            )
          end
  end

  # 미발행 잔여 — PAID 청구 중 issued 영수증이 없는 청구(발행 확정은 issued만 — CR-001).
  def unissued_entries(tenant, billable)
    paid_invoices = billable.select(&:PAID?)
    issued_invoice_ids = tenant.cash_receipts.issued
                               .where(invoice_id: paid_invoices.map(&:id)).pluck(:invoice_id)
    paid_invoices.reject { |invoice| issued_invoice_ids.include?(invoice.id) }
                 .map do |invoice|
                   UnissuedEntry.new(invoice_id: invoice.id,
                                     student_name: invoice.student_name_snapshot,
                                     total_amount: invoice.total_amount)
                 end
  end

  # 미납 명단(리포트) — 잔액 0 초과 billable 청구(부분납 잔액 포함 — INV-005).
  def unpaid_entries(billable, paid_totals)
    billable.filter_map do |invoice|
      paid = paid_totals.fetch(invoice.id, 0)
      balance = invoice.total_amount - paid
      next if balance <= 0

      UnpaidEntry.new(invoice_id: invoice.id,
                      student_name: invoice.student_name_snapshot,
                      total_amount: invoice.total_amount,
                      paid_amount: paid,
                      balance: balance)
    end
  end

  # 발행 요약(리포트) — 당월 영수증 상태별 건수(7종 모두 0 포함 제공 — 리포트 완결성).
  def receipt_state_counts(tenant, month)
    counts = tenant.cash_receipts.joins(:invoice)
                   .where(invoices: { target_month: month }).group(:state).count
    CashReceipt.states.keys.index_with { |key| counts.fetch(key, 0) }
  end

  def month_end_date_for(month)
    year, mon = month.split("-").map { |part| Integer(part, 10) }
    Date.new(year, mon, -1)
  end
end
