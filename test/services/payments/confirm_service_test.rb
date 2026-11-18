# frozen_string_literal: true

require "test_helper"

# 입금 확인 서비스 테스트 — PAY-001~004, CR-002(완납 시 origin:auto 1회·부분납 미호출),
# INV-003/005. Triggerable은 singleton 스파이로 대체 — 외부 실호출 없음(포트원·바로빌·솔라피 금지).
class Payments::ConfirmServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "입금확인테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT) # total_amount 250_000
    @service = Payments::ConfirmService.new
  end

  # Triggerable 스파이 — 호출 기록(calls)을 블록으로 전달, outcome·예외 주입 가능
  def stub_trigger(outcome: :created, raise_error: nil)
    original = CashReceipt::Triggerable.method(:trigger_issue_for)
    calls = []
    CashReceipt::Triggerable.define_singleton_method(:trigger_issue_for) do |invoice, issued_by:, origin:|
      calls << { invoice_id: invoice.id, issued_by: issued_by, origin: origin }
      raise raise_error if raise_error

      CashReceipt::Triggerable::Result.new(receipt: nil, outcome: outcome)
    end
    yield calls
  ensure
    CashReceipt::Triggerable.define_singleton_method(:trigger_issue_for, original)
  end

  def confirm(amount:, invoice: @invoice)
    @service.call(invoice: invoice, amount: amount, paid_on: Date.current,
                  method: "transfer", memo: nil, confirmed_by: "01033334444")
  end

  # CR-002: 자동발행 트리거는 '입금 확인'에서만 — 전액 확인(PAID 전이) 시 origin: :auto 정확히 1회
  test "CR-002 전액 확인은 PAID 전이와 origin:auto 트리거 1회를 수행한다" do
    stub_trigger do |calls|
      result = confirm(amount: 250_000)

      assert result.success?
      assert result.payment.reload.active?
      assert @invoice.reload.PAID?
      assert_equal 1, calls.size
      assert_equal :auto, calls.first[:origin]
      assert_equal @invoice.id, calls.first[:invoice_id]
      assert_equal "010-****-4444", result.payment.confirmed_by # TEN-003 마스킹
    end
  end

  # 부분납: PARTIALLY_PAID 전이 — 자동발행 보류(PRD 14장 확정), 트리거 미호출
  test "부분납은 PARTIALLY_PAID로 전이하고 트리거를 호출하지 않는다" do
    stub_trigger do |calls|
      result = confirm(amount: 100_000)

      assert result.success?
      assert result.payment.reload.active?
      assert @invoice.reload.PARTIALLY_PAID?
      assert_nil result.trigger
      assert_empty calls
    end
  end

  # PAY-001: 완납 처리된 청구의 재완납(중복 수납 등록) 차단 — 트리거 재호출도 없음
  test "PAY-001 완납 청구의 재수납은 거절되고 트리거를 재호출하지 않는다" do
    stub_trigger do |calls|
      confirm(amount: 250_000)
      result = confirm(amount: 10_000)

      assert_not result.success?
      assert result.payment.errors.of_kind?(:base, :already_fully_paid)
      assert_equal 1, Payment.count
      assert_equal 1, calls.size # 첫 확인 때의 1회뿐
    end
  end

  # PAY-004: 입금 확인과 발행은 별개 상태 — 트리거 예외가 수납 성공을 롤백하지 않는다
  test "PAY-004 발행 트리거 실패는 수납·PAID 전이를 보존한다" do
    stub_trigger(raise_error: StandardError.new("barobill unavailable")) do |_calls|
      result = confirm(amount: 250_000)

      assert result.success?
      assert result.payment.reload.active?
      assert @invoice.reload.PAID?
      assert_nil result.trigger # 발행은 별도 경로(재시도·수동)로 후속 처리
    end
  end

  # Triggerable duplicate(CR-001 멱등 skip) 응답은 무해 — 수납 성공 유지, 로그성 기록만
  test "트리거 duplicate 응답은 수납 성공에 영향을 주지 않는다" do
    stub_trigger(outcome: :duplicate) do |_calls|
      result = confirm(amount: 250_000)

      assert result.success?
      assert_equal :duplicate, result.trigger.outcome
      assert_equal :duplicate, result.issue_outcome
    end
  end

  # INV-003: 취소 청구 수납 거절
  test "INV-003 취소 청구의 수납 등록은 거절된다" do
    assert @invoice.cancel!("청구 취소")

    result = confirm(amount: 100_000)

    assert_not result.success?
    assert result.payment.errors.of_kind?(:invoice, :cancelled_invoice)
    assert_equal 0, Payment.count
  end

  # 초안(DRAFT) 청구 수납 거절 — 서비스 직접 호출 경로 차단(컨트롤러는 리스트에서 차단)
  test "초안(DRAFT) 청구의 수납 등록은 거절된다" do
    @invoice.update!(status: :DRAFT)

    result = confirm(amount: 100_000)

    assert_not result.success?
    assert result.payment.errors.of_kind?(:invoice, :draft_invoice)
    assert_equal 0, Payment.count
    assert @invoice.reload.DRAFT? # 상태 전이 없음
  end

  # PAY-002: 오체크 취소는 삭제가 아닌 이력 — 사유·처리자·시각 기록 + UNPAID 복원(기한 미경과)
  test "PAY-002 오체크 취소는 이력으로 남고 invoice는 UNPAID로 복원된다" do
    stub_trigger do |_calls|
      payment = confirm(amount: 250_000).payment # PAID 전이

      result = @service.cancel(payment, reason: "오체크", cancelled_by: "01033334444")

      assert result.success?
      assert payment.reload.cancelled?
      assert_equal "오체크", payment.cancel_reason
      assert_equal "010-****-4444", payment.cancelled_by # TEN-003 마스킹
      assert payment.cancelled_at.present?
      assert @invoice.reload.UNPAID? # create_invoice 기본 due_on=오늘 → 기한 미경과
    end
  end

  # PAY-002: 취소 재계산 — 기한 경과 청구는 OVERDUE 복원
  test "기한이 경과한 청구의 전액 취소는 OVERDUE로 복원된다" do
    stub_trigger do |_calls|
      @invoice.update!(due_on: Date.current - 3.days)
      payment = confirm(amount: 250_000).payment

      assert @service.cancel(payment, reason: "오체크", cancelled_by: "01033334444").success?
      assert @invoice.reload.OVERDUE?
    end
  end

  # PAY-002: 복수 수납 중 1건 취소 — 잔여 active 합계로 PARTIALLY_PAID 유지(INV-005)
  test "복수 수납 중 1건 취소 시 부분 합계면 PARTIALLY_PAID를 유지한다" do
    stub_trigger do |_calls|
      first = confirm(amount: 100_000).payment
      second = confirm(amount: 150_000).payment # 이때 PAID 전이 + 트리거 1회

      assert @invoice.reload.PAID?
      assert @service.cancel(second, reason: "오체크", cancelled_by: "01033334444").success?

      assert @invoice.reload.PARTIALLY_PAID?
      assert_equal 100_000, Payment.paid_total_for(@invoice)
      assert first.reload.active?
    end
  end

  # PAY-002: 재취소 거절(취소 이력의 재취소 불가)
  test "PAY-002 취소된 수납의 재취소는 거절된다" do
    stub_trigger do |_calls|
      payment = confirm(amount: 250_000).payment
      assert @service.cancel(payment, reason: "오체크", cancelled_by: "01033334444").success?

      result = @service.cancel(payment, reason: "재취소 시도", cancelled_by: "01033334444")

      assert_not result.success?
      assert payment.reload.cancelled?
    end
  end

  # PAY-002: 취소 사유 누락 거절
  test "PAY-002 취소 사유가 없으면 거절된다" do
    stub_trigger do |_calls|
      payment = confirm(amount: 100_000).payment

      result = @service.cancel(payment, reason: "   ", cancelled_by: "01033334444")

      assert_not result.success?
      assert payment.reload.active? # 취소 전이 없음
      assert @invoice.reload.PARTIALLY_PAID?
    end
  end

  # CR-002 1회성 조합 — 완납 이후 재수납 차단(PAY-001)·수동 재발급·오체크 취소가 섞여도
  # origin: :auto 호출은 1회로 유지된다(수동 경로는 :manual로 구분 기록).
  test "CR-002 완납 이후 재수납 차단·수동 재발급·취소 조합에서 auto 트리거는 1회로 유지된다" do
    stub_trigger do |calls|
      confirm(amount: 250_000) # PAID 전이 + auto 1회
      assert_equal 1, calls.size

      # 재수납 차단(PAY-001) — 트리거 추가 호출 없음
      assert_not confirm(amount: 10_000).success?
      assert_equal 1, calls.size

      # 수동 재발급 시도 — 별도 origin(:manual)으로 기록, auto 집계와 구분된다
      CashReceipt::Triggerable.trigger_issue_for(@invoice, issued_by: "01033334444", origin: :manual)
      assert_equal 2, calls.size

      # 오체크 취소 — 상태 재계산은 트리거를 호출하지 않는다
      payment = Payment.active.find_by!(invoice_id: @invoice.id)
      assert @service.cancel(payment, reason: "오체크", cancelled_by: "01033334444").success?
      assert @invoice.reload.UNPAID?

      assert_equal 1, calls.count { |c| c[:origin] == :auto } # auto 1회 유지
      assert_equal :manual, calls.last[:origin]               # 나머지 1건은 수동
    end
  end

  # CR-002 — 오체크 취소로 UNPAID 복원 후 재완납하면 '새 PAID 전이'로서 트리거가 다시 1회
  # 호출된다(1회성은 청구 생애가 아닌 PAID 전이 단위). 실제 중복 발행은 Triggerable 내부의
  # CR-001 멱등(mgt_key)이 차단한다.
  test "CR-002 오체크 취소 후 재완납하면 새 PAID 전이로 트리거가 다시 1회 호출된다" do
    stub_trigger do |calls|
      first = confirm(amount: 250_000)
      assert first.success?
      assert_equal 1, calls.size

      assert @service.cancel(first.payment, reason: "오체크", cancelled_by: "01033334444").success?
      assert @invoice.reload.UNPAID?
      assert_equal 1, calls.size # 취소 자체는 트리거 없음

      second = confirm(amount: 250_000)
      assert second.success?
      assert @invoice.reload.PAID?
      assert_equal 2, calls.size # 재완납 전이 시점 1회 추가
      assert_equal [ :auto, :auto ], calls.map { |c| c[:origin] }
    end
  end

  # CR-002 — 부분납 시점엔 보류, 추가 수납으로 완납 전이하는 그 시점에 1회(PRD 14장 확정).
  test "부분납 청구의 추가 수납으로 완납 전이 시 그 시점에 트리거가 1회 호출된다" do
    stub_trigger do |calls|
      first = confirm(amount: 100_000)
      assert first.success?
      assert @invoice.reload.PARTIALLY_PAID?
      assert_empty calls # 부분납 — 자동발행 보류

      second = confirm(amount: 150_000)
      assert second.success?
      assert second.payment.reload.active?
      assert @invoice.reload.PAID?
      assert_equal 1, calls.size # 완납 전이 시점 1회
      assert_equal :auto, calls.first[:origin]
      assert_equal @invoice.id, calls.first[:invoice_id]
    end
  end
end
