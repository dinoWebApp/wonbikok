# frozen_string_literal: true

require "test_helper"

# 마감 대시보드 집계 서비스 테스트 (W4 F7 — PRD 7장 F7).
# 지표 정산(청구/수납/미납/납부율 — 취소 제외·부분납 반영), 오늘 할 일(미확인 입금·발행 실패·
# 다가오는 리마인더), 미발행 잔여(PAID × issued 없음), 마감 완료 판정(수납 100%·월 경과),
# 월말 플래그, 빈 상태 구분, 미납 명단, TEN-001 테넌트 격리. 읽기 전용 집계 — 외부 호출 없음.
class Dashboard::SummaryServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @user = create_owner_user
    @student = create_student_with_guardian(tenant: @tenant)
    @month = Date.current.strftime("%Y-%m")
  end

  def build_result(month: @month, on: Date.current)
    Dashboard::SummaryService.new.call(tenant: @tenant, month: month, on: on)
  end

  def create_active_payment(invoice, amount:)
    Payment.create!(tenant: invoice.tenant, invoice: invoice, status: :active,
                    amount: amount, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
  end

  def create_receipt(invoice, state:, mgt_key:)
    CashReceipt.create!(tenant: invoice.tenant, invoice: invoice,
                        mgt_key: mgt_key, amount: invoice.total_amount, state: state)
  end

  def create_paid_invoice_for(name, base_amount: 250_000, target_month: nil)
    student = create_student_with_guardian(tenant: @tenant, name: name)
    invoice = create_invoice(@tenant, student, status: :PAID,
                             base_amount: base_amount,
                             target_month: target_month || @month)
    create_active_payment(invoice, amount: base_amount)
    invoice
  end

  test "지표 정산 — 청구·수납·미납·납부율(취소 제외·부분납 반영)과 기준 라벨" do
    invoice = create_invoice(@tenant, @student, status: :PARTIALLY_PAID) # 250_000
    create_active_payment(invoice, amount: 100_000)
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "이서윤"),
                   status: :CANCELLED, base_amount: 200_000) # INV-003 취소 청구

    result = build_result

    assert_equal 250_000, result.billed_amount # 취소 200,000 제외
    assert_equal 100_000, result.paid_amount   # active 수납만(PAY-002)
    assert_equal 150_000, result.unpaid_amount
    assert_equal 40, result.payment_rate       # 100,000 / 250,000
    assert_equal :billable_excluding_cancelled, result.billed_basis
    assert_equal :actual_payment_records, result.paid_basis
  end

  test "취소 전환된 청구의 수납은 정산에서 제외된다(INV-003)" do
    invoice = create_invoice(@tenant, @student, status: :SENT)
    create_active_payment(invoice, amount: 100_000) # 부분 수납
    invoice.cancel!("등록 오류") # SENT → 취소 전환(수납 이력은 active로 잔존)

    result = build_result

    assert_equal 1, Payment.active.count # 이력은 유지되지만
    assert_equal 0, result.billed_amount
    assert_equal 0, result.paid_amount   # billable 제외로 정산 미포함
    assert_equal 0, result.unpaid_amount
    assert_nil result.payment_rate       # 청구 0 — 납부율 미산출
  end

  test "미확인 입금 — 미완납 확정 청구만 집계(payments 리스트와 동일 기준)" do
    create_invoice(@tenant, @student, status: :SENT) # 집계 대상
    partial = create_invoice(@tenant,
                             create_student_with_guardian(tenant: @tenant, name: "이서윤"),
                             status: :PARTIALLY_PAID, base_amount: 200_000)
    create_active_payment(partial, amount: 50_000) # 집계 대상(잔액 150,000)
    create_paid_invoice_for("박도윤") # 제외 — 완납
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "정하윤"),
                   status: :DRAFT) # 제외 — 초안
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "한지호"),
                   status: :CANCELLED) # 제외 — 취소
    past_month = 2.months.ago.strftime("%Y-%m")
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "고민우"),
                   status: :SENT, target_month: past_month) # 제외 — 타월

    assert_equal 2, build_result.unconfirmed_payments_count
  end

  test "발행 실패 건수와 발행 요약 — 당월 영수증 상태별 집계" do
    paid = create_paid_invoice_for("이서윤")
    create_receipt(paid, state: :failed, mgt_key: "CRS1")
    issued = create_paid_invoice_for("박도윤")
    create_receipt(issued, state: :issued, mgt_key: "CRS2")
    past_paid = create_paid_invoice_for("정하윤", target_month: 2.months.ago.strftime("%Y-%m"))
    create_receipt(past_paid, state: :failed, mgt_key: "CRS3") # 타월 — 제외

    result = build_result

    assert_equal 1, result.failed_receipts_count
    assert_equal({
                   "needs_info" => 0, "pending" => 0, "processing" => 0,
                   "issued" => 1, "failed" => 1,
                   "cancel_pending" => 0, "cancelled" => 0
                 }, result.receipt_state_counts)
  end

  test "다가오는 리마인더 — remindable 기한 임박 순 상위·제외 원생 배제(MSG-004)" do
    on = Date.new(2026, 11, 18)
    urgent = create_invoice(@tenant, @student, status: :OVERDUE,
                            target_month: "2026-11", due_on: Date.new(2026, 11, 8))
    later = create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "이서윤"),
                           status: :OVERDUE, target_month: "2026-11",
                           due_on: Date.new(2026, 11, 16))
    excluded_student = create_student_with_guardian(tenant: @tenant, name: "박도윤")
    excluded_student.update!(excluded_from_reminders: true)
    create_invoice(@tenant, excluded_student, status: :OVERDUE,
                   target_month: "2026-11", due_on: Date.new(2026, 11, 10)) # MSG-004 배제

    result = Dashboard::SummaryService.new.call(tenant: @tenant, month: "2026-11", on: on)

    assert_equal 2, result.upcoming_reminders_count
    assert_equal [ urgent.id, later.id ], result.upcoming_reminders.map(&:invoice_id)
    assert_equal "김민준", result.upcoming_reminders.first.student_name
    assert_equal 10, result.upcoming_reminders.first.days_overdue
    assert_equal :d7, result.upcoming_reminders.first.stage
    assert_equal 2, result.upcoming_reminders.second.days_overdue
  end

  test "미발행 잔여 — PAID 청구 중 issued 영수증이 없는 청구만(CR-001)" do
    issued = create_paid_invoice_for("이서윤")
    create_receipt(issued, state: :issued, mgt_key: "CRU1")
    no_receipt = create_paid_invoice_for("박도윤") # 발행 이력 없음 → 대상
    failed_only = create_paid_invoice_for("정하윤")
    create_receipt(failed_only, state: :failed, mgt_key: "CRU2") # issued 없음 → 대상
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "한지호"),
                   status: :SENT) # 미완납 → 제외

    result = build_result

    assert_equal [ no_receipt.id, failed_only.id ], result.unissued_students.map(&:invoice_id)
    assert_equal "박도윤", result.unissued_students.first.student_name
    assert_equal 250_000, result.unissued_students.first.total_amount
  end

  test "마감 완료 판정 — 수납 100% 또는 월 경과" do
    create_paid_invoice_for("이서윤") # 수납 100%
    assert build_result.closing_complete?

    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "박도윤"),
                   status: :SENT) # 미납 잔존
    assert_not build_result.closing_complete? # 당월 — 미완료

    past_month = 2.months.ago.strftime("%Y-%m")
    past_result = build_result(month: past_month)
    assert past_result.month_elapsed?
    assert past_result.closing_complete? # 월 경과 — 미납 잔존해도 완료 표시
  end

  test "월말 플래그 — 말일 7일 이내 가산세 방지 강조" do
    assert build_result(month: "2026-11", on: Date.new(2026, 11, 25)).month_end_near?
    assert_not build_result(month: "2026-11", on: Date.new(2026, 11, 10)).month_end_near?
    assert_not build_result(month: "2026-11", on: Date.new(2026, 11, 25)).month_elapsed?
    assert build_result(month: "2026-10", on: Date.new(2026, 11, 2)).month_elapsed?
  end

  test "빈 상태 구분 — 원생 0은 no_students, 원생만 있고 청구 0은 no_invoices" do
    empty_tenant, _owner = create_owner_user(name: "빈 학원", phone_number: "01077776666")
    result = Dashboard::SummaryService.new.call(tenant: empty_tenant, month: @month)
    assert_equal :no_students, result.empty_state

    assert_equal :no_invoices, build_result.empty_state

    create_invoice(@tenant, @student, status: :SENT)
    assert_nil build_result.empty_state
  end

  test "미납 명단 — 잔액 0 초과 billable 청구를 원생명·금액으로 제공(리포트)" do
    partial = create_invoice(@tenant, @student, status: :PARTIALLY_PAID, base_amount: 300_000)
    create_active_payment(partial, amount: 100_000)
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "이서윤"),
                   status: :SENT) # 무수납 250,000
    create_paid_invoice_for("박도윤") # 완납 — 제외
    create_invoice(@tenant, create_student_with_guardian(tenant: @tenant, name: "정하윤"),
                   status: :CANCELLED) # 취소 — 제외

    result = build_result

    assert_equal 2, result.unpaid_list.size
    first_entry = result.unpaid_list.first
    assert_equal partial.id, first_entry.invoice_id
    assert_equal "김민준", first_entry.student_name
    assert_equal 300_000, first_entry.total_amount
    assert_equal 100_000, first_entry.paid_amount
    assert_equal 200_000, first_entry.balance
  end

  test "TEN-001 — 타 테넌트 청구·수납·영수증은 집계에서 제외된다" do
    other_tenant, _other_user = create_owner_user(name: "다른 학원", phone_number: "01088887777")
    other_student = create_student_with_guardian(tenant: other_tenant, name: "외부원생")
    other_invoice = create_invoice(other_tenant, other_student, status: :PARTIALLY_PAID)
    Payment.create!(tenant: other_tenant, invoice: other_invoice, status: :active,
                    amount: 250_000, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
    create_receipt(other_invoice, state: :failed, mgt_key: "CRT1")

    result = build_result

    assert_equal 0, result.billed_amount
    assert_equal 0, result.paid_amount
    assert_equal 0, result.unconfirmed_payments_count
    assert_equal 0, result.failed_receipts_count
    assert_empty result.unissued_students
    assert_empty result.unpaid_list
  end
end
