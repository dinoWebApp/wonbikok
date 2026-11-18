# frozen_string_literal: true

require "test_helper"

# 입금 매칭 힌트 테스트 — PAY-003(추천 전용·자동 선택 없음), TEN-001(테넌트 격리),
# INV-003(취소 청구 제외), PAY-001(PAID 제외)
class Payments::MatchingHintServiceTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(name: "힌트테스트 학원", onboarding_step: 6)
    @student = create_student_with_guardian(tenant: @tenant) # 김민준
    @invoice = create_invoice(@tenant, @student, status: :SENT) # 250_000
    @service = Payments::MatchingHintService.new(tenant: @tenant)
  end

  def create_payment(invoice, amount:)
    Payment.create!(tenant: invoice.tenant, invoice: invoice, status: :active,
                    amount: amount, paid_on: Date.current, method: "transfer",
                    confirmed_by: "01033334444", confirmed_at: Time.current)
  end

  test "금액 정확 일치(청구 총액) 청구를 후보로 반환한다" do
    candidates = @service.suggest(amount: 250_000)

    assert_equal [ @invoice.id ], candidates.map { |c| c.invoice.id }
    assert_equal :amount, candidates.first.matched_on
  end

  test "금액이 일치하지 않으면 후보가 없다" do
    assert_empty @service.suggest(amount: 300_000)
  end

  test "완납(PAID)·취소(CANCELLED)·초안(DRAFT) 청구는 후보에서 제외된다" do
    create_payment(@invoice, amount: 250_000)
    @invoice.update!(status: :PAID) # PAY-001 — 완납 청구 제외
    assert_empty @service.suggest(amount: 250_000)

    cancelled = create_invoice(@tenant,
                               create_student_with_guardian(tenant: @tenant, name: "취소원생"),
                               status: :CANCELLED) # INV-003 — 취소 청구 제외
    draft = create_invoice(@tenant,
                           create_student_with_guardian(tenant: @tenant, name: "초안원생"),
                           status: :DRAFT)

    assert_empty @service.suggest(amount: 250_000, name: "원생")
    assert_empty [ cancelled, draft ].select { |invoice|
      candidates = @service.suggest(amount: invoice.total_amount)
      candidates.map(&:invoice).include?(invoice)
    }
  end

  test "원생명 유사 청구를 후보로 반환한다" do
    candidates = @service.suggest(name: "민준")

    assert_equal [ @invoice.id ], candidates.map { |c| c.invoice.id }
    assert_equal :name, candidates.first.matched_on
  end

  test "부분납 청구(미완납)는 후보 대상에 포함된다" do
    create_payment(@invoice, amount: 100_000)
    @invoice.update!(status: :PARTIALLY_PAID)

    candidates = @service.suggest(amount: 250_000, name: "민준")

    assert_equal @invoice.id, candidates.first.invoice.id
  end

  test "금액 일치 후보가 이름 유사 후보보다 먼저 온다" do
    other = create_invoice(@tenant,
                           create_student_with_guardian(tenant: @tenant, name: "김민준2"),
                           status: :SENT, base_amount: 180_000)

    candidates = @service.suggest(amount: 250_000, name: "민준")

    assert_equal 2, candidates.size
    assert_equal [ @invoice.id, other.id ], candidates.map { |c| c.invoice.id }
    assert_equal :amount, candidates.first.matched_on
    assert_equal :name, candidates.last.matched_on
  end

  # TEN-001: 타 테넌트 청구는 후보에 포함되지 않는다
  test "TEN-001 타 테넌트 청구는 후보에서 제외된다" do
    other_tenant, _other_user = create_owner_user(name: "다른 학원", phone_number: "01088887777")
    other_invoice = create_invoice(other_tenant,
                                   create_student_with_guardian(tenant: other_tenant, name: "외부원생"),
                                   status: :SENT)

    candidates = @service.suggest(amount: 250_000, name: "외부")

    # 자기 테넌트 청구(setup @invoice — 금액 일치)는 유효 후보로 남고,
    # 타 테넌트 청구(외부원생)만 배제되면 TEN-001 격리 충족
    assert_not_includes candidates.map { |c| c.invoice.id }, other_invoice.id
    assert candidates.all? { |c| c.invoice.tenant_id == @tenant.id }
  end

  # PAY-003: 반환은 후보 목록만 — 자동 선택 개념(선택 플래그)이 없다
  test "PAY-003 반환은 후보 목록만이며 선택 상태 개념이 없다" do
    candidates = @service.suggest(amount: 250_000, name: "민준")

    assert_kind_of Array, candidates
    assert candidates.all? { |c| c.is_a?(Payments::MatchingHintService::Candidate) }
    assert_not candidates.first.respond_to?(:selected?)
    assert_not candidates.first.respond_to?(:selected)
  end

  test "잘못된 월 형식은 당월로 보정된다" do
    service = Payments::MatchingHintService.new(tenant: @tenant, month: "2026-13")

    assert_not_empty service.suggest(amount: 250_000)
  end
end
