require "test_helper"

class CashReceiptTriggerableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @tenant, @user = create_owner_user
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT)
  end

  test "수동 트리거로 pending 영수증 생성 + IssueJob enqueue된다" do
    assert_enqueued_with job: CashReceipt::IssueJob do
      result = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: @user.phone_number)

      assert result.created?
      assert result.receipt.pending?
      assert_equal CashReceipt.build_mgt_key(@invoice, :income_deduction), result.receipt.mgt_key
      assert_equal @invoice.total_amount, result.receipt.amount
      # C4(TEN-003): 처리자 휴대폰번호는 마스킹 저장 — 원문 없음
      assert_equal "010-****-4444", result.receipt.issued_by
    end
  end

  test "CR-001 동일 청구 재트리거는 skip(기존 건 반환)" do
    first = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "system")
    second = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "system")

    assert first.created?
    assert second.duplicate?
    assert_equal first.receipt.id, second.receipt.id
    assert_equal 1, CashReceipt.count
  end

  test "CR-002 취소 청구는 발행 차단된다(C3: manual은 CANCELLED만 차단)" do
    cancelled = create_invoice(@tenant, @student, status: :CANCELLED, target_month: "2026-09")
    draft = create_invoice(@tenant, @student, status: :DRAFT, target_month: "2026-10")

    assert CashReceipt::Triggerable.trigger_issue_for(cancelled, issued_by: "system").blocked?
    assert CashReceipt::Triggerable.trigger_issue_for(draft, issued_by: "system").created? # manual 허용
  end

  test "CR-002(C3) auto 트리거는 수납 확인 완료(PAID·PARTIALLY_PAID) 청구만 허용된다" do
    unpaid = create_invoice(@tenant, @student, status: :UNPAID, target_month: "2026-10")
    paid = create_invoice(@tenant, @student, status: :PAID, target_month: "2026-09")
    partially_paid = create_invoice(@tenant, @student, status: :PARTIALLY_PAID, target_month: "2026-08")

    assert CashReceipt::Triggerable.trigger_issue_for(unpaid, issued_by: "system", origin: :auto).blocked?
    assert CashReceipt::Triggerable.trigger_issue_for(paid, issued_by: "system", origin: :auto).created?
    assert CashReceipt::Triggerable.trigger_issue_for(partially_paid, issued_by: "system", origin: :auto).created?
  end

  test "W6 동시 생성 레이스 — RecordNotUnique 시 duplicate 응답 통일(CR-001)" do
    first = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "system")
    assert first.created?

    original = CashReceipt.method(:find_by)
    calls = 0
    CashReceipt.define_singleton_method(:find_by) do |*args, **kwargs|
      calls += 1
      calls == 1 ? nil : original.call(*args, **kwargs) # 첫 find_by만 nil — create!까지 진입해 레이스 재현
    end
    begin
      result = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "system")
    ensure
      CashReceipt.singleton_class.send(:remove_method, :find_by)
    end

    assert result.duplicate?
    assert_equal first.receipt.id, result.receipt.id
    assert_equal 1, CashReceipt.count
  end

  test "수취인 정보 미비 시 needs_info로 생성되고 큐에 진입하지 않는다" do
    @student.primary_guardian.update!(phone_number: "01099998888")
    # 지급증명용이고 사업자번호 없음 → needs_info
    @student.update!(cash_receipt_issue_type: :expense_evidence)

    assert_no_enqueued_jobs only: CashReceipt::IssueJob do
      result = CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "system")

      assert result.needs_info?
      assert result.receipt.needs_info?
    end
  end
end
