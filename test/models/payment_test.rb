# frozen_string_literal: true

require "test_helper"

# 수납 도메인 테스트 — PAY-001(완납 재처리 차단), PAY-002(취소 이력),
# INV-003(취소 청구 수납 금지), TEN-001(테넌트 격리), TEN-003(처리자 마스킹)
class PaymentTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "수납테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant)
    @invoice = create_invoice(@tenant, @student, status: :SENT) # total_amount 250_000
  end

  def build_payment(attrs = {})
    Payment.new({
      tenant: @tenant, invoice: @invoice, status: :active,
      amount: 250_000, paid_on: Date.current, method: "transfer",
      memo: nil, confirmed_by: "01033334444", confirmed_at: Time.current
    }.merge(attrs))
  end

  test "정상 active 수납을 생성한다" do
    payment = build_payment
    assert payment.valid?
    assert payment.save
    assert payment.active?
  end

  # PAY-001: 완납(active 합계 >= 총액) 후 추가 active 수납은 모델 검증으로 거절
  test "PAY-001 완납 합계 도달 후 추가 active 수납은 거절된다" do
    build_payment.save!

    second = build_payment(amount: 10_000)
    assert_not second.valid?
    assert second.errors.of_kind?(:base, :already_fully_paid)
  end

  # PAY-001: 취소된 수납은 합계에서 제외 — 재등록 가능(오체크 → 재확인 흐름)
  test "PAY-001 취소 이력은 합계에서 제외되어 재등록이 가능하다" do
    payment = build_payment
    payment.save!
    payment.update!(status: :cancelled, cancel_reason: "오체크",
                    cancelled_at: Time.current, cancelled_by: "01033334444")

    assert build_payment.valid?
    assert_equal 0, Payment.paid_total_for(@invoice)
  end

  test "금액 0·음수는 거절된다" do
    assert_not build_payment(amount: 0).valid?
    assert_not build_payment(amount: -1).valid?
  end

  test "입금일 미래는 거절된다" do
    payment = build_payment(paid_on: Date.current + 1.day)
    assert_not payment.valid?
    assert payment.errors.of_kind?(:paid_on, :future_date)
  end

  test "수단은 허용 목록(transfer·card·cash·other)로 제한된다" do
    assert_equal %w[transfer card cash other].sort, Payment::PAYMENT_METHODS.sort
    assert_not build_payment(method: "bitcoin").valid?
    assert build_payment(method: "card").valid?
  end

  # PAY-002: 취소 전이 시 사유 필수
  test "PAY-002 취소 전이에는 사유가 필수다" do
    payment = build_payment
    payment.save!
    payment.status = :cancelled

    assert_not payment.valid?
    assert payment.errors.of_kind?(:cancel_reason, :blank)
  end

  # PAY-002: 취소된 수납의 재취소(상태 부활) 금지
  test "PAY-002 취소된 수납의 상태 복원은 거절된다" do
    payment = build_payment
    payment.save!
    payment.update!(status: :cancelled, cancel_reason: "오체크",
                    cancelled_at: Time.current, cancelled_by: "01033334444")
    payment.status = :active

    assert_not payment.valid?
    assert payment.errors.of_kind?(:status, :already_cancelled)
  end

  # INV-003: 취소 청구에는 수납 등록 불가
  test "INV-003 취소 청구에는 수납을 등록할 수 없다" do
    assert @invoice.cancel!("청구 취소")

    payment = build_payment
    assert_not payment.valid?
    assert payment.errors.of_kind?(:invoice, :cancelled_invoice)
  end

  # TEN-001: tenant와 invoice의 테넌트 불일치 거절
  test "TEN-001 tenant-invoice 불일치 수납은 거절된다" do
    other_tenant, _other_user = create_owner_user(name: "다른 학원", phone_number: "01099998888")

    payment = build_payment(tenant: other_tenant)
    assert_not payment.valid?
    assert payment.errors.of_kind?(:tenant, :tenant_mismatch)
  end

  # TEN-001: for_tenant 스코프 격리
  test "TEN-001 for_tenant 스코프는 타 테넌트 수납을 제외한다" do
    other_tenant, _other_user = create_owner_user(name: "다른 학원", phone_number: "01099998888")
    other_invoice = create_invoice(other_tenant,
                                   create_student_with_guardian(tenant: other_tenant, name: "외부원생"),
                                   status: :SENT)
    other_payment = build_payment(tenant: other_tenant, invoice: other_invoice)
    other_payment.save!
    mine = build_payment
    mine.save!

    ids = Payment.for_tenant(@tenant).ids
    assert_includes ids, mine.id
    assert_not_includes ids, other_payment.id
  end

  # TEN-003: 처리자 휴대폰번호 원문 저장 금지 — 마스킹 저장(CashReceipt#issued_by= 동일 패턴)
  test "TEN-003 처리자 번호는 마스킹되어 저장된다" do
    payment = build_payment
    payment.save!

    assert_equal "010-****-4444", payment.reload.confirmed_by
    assert_equal "010-****-4444", build_payment(cancelled_by: "01033334444").cancelled_by
    # 휴대폰 형식이 아닌 표기는 원문 보존(예: "원장 직접 확인")
    assert_equal "원장 직접 확인", build_payment(confirmed_by: "원장 직접 확인").confirmed_by
  end

  test "paid_total_for는 active 수납만 합산한다" do
    build_payment(amount: 100_000).save!
    build_payment(amount: 50_000).save!
    cancelled = build_payment(amount: 70_000)
    cancelled.save!
    cancelled.update!(status: :cancelled, cancel_reason: "오체크",
                      cancelled_at: Time.current, cancelled_by: "01033334444")

    assert_equal 150_000, Payment.paid_total_for(@invoice)
  end
end
