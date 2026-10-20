# frozen_string_literal: true

# 청구 도메인 테스트 — INV-001/002/003/004/006, TEN-004
class InvoiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "청구테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
  end

  # INV-001: 같은 원생 × 같은 월 중복 청구 생성 금지 — 모델 검증
  test "INV-001 같은 원생 같은 월 중복 생성은 모델 검증으로 차단된다" do
    create_invoice(@tenant, @student)

    duplicate = @tenant.invoices.new(
      student: @student, target_month: Date.current.strftime("%Y-%m"),
      student_name_snapshot: @student.name, base_amount: @student.monthly_fee
    )
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:student_id, :taken)
  end

  # INV-001: DB 유니크 제약(검증 우회 삽입도 차단)
  test "INV-001 검증 우회 삽입은 DB 유니크 인덱스로 차단된다" do
    invoice = create_invoice(@tenant, @student)

    assert_raises(ActiveRecord::RecordNotUnique) do
      invoice.dup.save!(validate: false)
    end
  end

  # INV-001: Generator 재실행 멱등 — created=0/skipped=N
  test "INV-001 Generator 재실행은 멱등하게 skip된다" do
    @tenant.students.create!(name: "휴원원생", grade: "초3", monthly_fee: 200_000,
                             payment_day: 25, status: :paused, ended_on: Date.current)
    month = Date.current.strftime("%Y-%m")

    first = Invoices::Generator.new(tenant: @tenant, target_month: month).call
    assert_equal 1, first.created # INV-004: active 원생만 생성 대상

    second = Invoices::Generator.new(tenant: @tenant, target_month: month).call
    assert_equal 0, second.created
    assert_equal 1, second.skipped
    assert_equal 1, second.excluded
    assert_equal 1, @tenant.invoices.for_month(month).count
  end

  # TEN-004: 스냅샷 — 원생 기본 원비·이름 변경 후 기존 청구 불변
  test "TEN-004 원생 정보 변경 후에도 기존 청구 스냅샷은 불변이다" do
    invoice = create_invoice(@tenant, @student)

    @student.update!(monthly_fee: 999_000, name: "개명된원생")

    assert_equal "김민준", invoice.reload.student_name_snapshot
    assert_equal 250_000, invoice.base_amount
    assert_equal 250_000, invoice.total_amount
  end

  # INV-002: READY(확정) 이후 조정은 사유 필수 + 이력 기록
  test "INV-002 READY 청구 조정은 사유 없이 실패하고 사유와 함께 성공·이력 기록된다" do
    invoice = create_invoice(@tenant, @student)
    invoice.confirm!
    assert invoice.READY?

    assert_not invoice.adjust!(adjustment_amount: 10_000, adjustment_note: "", change_reason: nil)
    assert invoice.errors.of_kind?(:change_reason, :blank)
    assert_equal 0, invoice.adjustment_amount

    assert invoice.adjust!(adjustment_amount: 10_000, adjustment_note: "교재비",
                           change_reason: "교재비 추가")
    assert_equal 10_000, invoice.reload.adjustment_amount
    entries = invoice.change_history_entries
    assert_equal 1, entries.size
    assert_equal "교재비 추가", entries.first["reason"]
  end

  # INV-002/INV-006: DRAFT는 사유 없이 자유 수정
  test "INV-006 DRAFT 청구는 사유 없이 조정된다" do
    invoice = create_invoice(@tenant, @student)

    assert invoice.adjust!(adjustment_amount: -5_000, adjustment_note: "형제 할인")
    assert_equal(-5_000, invoice.reload.adjustment_amount)
    assert_empty invoice.change_history_entries # 사유 이력 없음(DRAFT)
  end

  # INV-006: SENT·CANCELLED 청구는 조정 불가
  test "INV-006 SENT와 CANCELLED 청구의 조정은 차단된다" do
    sent = create_invoice(@tenant, @student, status: :SENT, sent_at: Time.current)
    cancelled = create_invoice(@tenant, @student, target_month: 1.month.ago.strftime("%Y-%m"),
                                                   status: :CANCELLED, cancel_reason: "중복")

    [ sent, cancelled ].each do |invoice|
      assert_not invoice.adjust!(adjustment_amount: 1, adjustment_note: "", change_reason: "사유")
      assert invoice.errors.of_kind?(:status, :invalid)
      assert_equal 0, invoice.reload.adjustment_amount
    end
  end

  # INV-003: CANCELLED 청구는 billable(수납 합계 대상)·remindable에서 제외
  test "INV-003 취소 청구는 billable과 remindable에서 제외된다" do
    invoice = create_invoice(@tenant, @student)
    invoice.confirm!
    invoice.mark_sent!
    invoice.cancel!("이중 발급")
    other = create_invoice(@tenant, @student, target_month: 1.month.ago.strftime("%Y-%m"))
    other.update!(status: :SENT, sent_at: Time.current, due_on: 3.days.ago)

    assert_not_includes Invoice.billable, invoice.reload
    assert_includes Invoice.billable, other
    assert_not_includes Invoice.remindable, invoice.reload
    assert_includes Invoice.remindable, other.reload
  end

  # INV-003/9.1: 취소 시 QUEUED 발송 예약 연쇄 취소(FAILED/INVOICE_CANCELLED)
  test "INV-003 취소 시 대기 중인 예약 발송이 연쇄 차단된다" do
    invoice = create_invoice(@tenant, @student)
    invoice.confirm!
    log = invoice.message_logs.create!(tenant: @tenant, student: @student,
                                       template_type: :invoice_notice, status: :QUEUED)

    assert invoice.cancel!("중복 발급")
    assert_equal "FAILED", log.reload.status
    assert_equal "INVOICE_CANCELLED", log.error_code
  end

  # INV-003: 취소 사유는 필수(빈 사유 → false + 검증 오류, 500 아님)
  test "INV-003 취소 사유가 비면 취소되지 않고 검증 오류를 낸다" do
    invoice = create_invoice(@tenant, @student)

    assert_not invoice.cancel!("   ")
    assert invoice.errors.of_kind?(:cancel_reason, :blank)
    assert_not invoice.reload.CANCELLED?
  end
end
