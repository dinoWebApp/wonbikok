# 수납 내역 (PRD 7장 F4, 14장 W3 F4/F9 확정 사항).
# PAY-001: 완납 청구의 재수납(중복 등록) 차단 — active 합계가 총액 이상이면 신규 active 거절.
# PAY-002: 오체크는 삭제가 아닌 취소 이력(status: cancelled + 사유·처리자·시각).
# INV-003: 취소(CANCELLED) 청구에는 수납을 등록할 수 없다(수납 합계 제외).
# TEN-001: for_tenant 스코프로 테넌트 격리 조회. TEN-003: 처리자 번호는 마스킹 저장
#          (CashReceipt#issued_by=와 동일 패턴).
# 컬럼은 3-S 통합 마이그레이션에서 생성(invoice_id·tenant_id·amount·paid_on·method·memo·
# status·cancel_reason·cancelled_at·cancelled_by·confirmed_by·confirmed_at + 타임스탬프).
class Payment < ApplicationRecord
  # PRD 14장 — status 2종. enum이 `Payment.active`(유효 수납 스코프)를 자동 제공한다.
  enum :status, {
    active: "active",       # 유효 수납(합계·상태 계산 대상)
    cancelled: "cancelled"  # 취소 이력(PAY-002 — 삭제 없음)
  }, validate: true

  PAYMENT_METHODS = %w[transfer card cash other].freeze

  belongs_to :tenant
  belongs_to :invoice

  # 주의: 컬럼명이 `method`라 Object#method를 덮는다 — 이 모델 인스턴스에서
  # `.method(:sym)` 리플렉션 호출 금지.
  validates :amount, numericality: { greater_than: 0 }
  validates :paid_on, presence: true
  validates :method, presence: true, inclusion: { in: PAYMENT_METHODS }
  validates :cancel_reason, presence: true, if: :cancelled?
  validate :paid_on_not_in_future
  validate :tenant_matches_invoice
  validate :invoice_accepts_payment, on: :create
  validate :reject_when_already_paid, on: :create, if: -> { !cancelled? && invoice.present? }
  validate :no_resurrection_of_cancelled, on: :update

  scope :for_tenant, ->(tenant) { where(tenant: tenant) } # TEN-001

  # active 수납 합계 — ConfirmService·매칭 힌트·취소 재계산 공용.
  # 취소 이력 제외(PAY-002), 취소 청구 건은 애초 생성 불가(INV-003).
  def self.paid_total_for(invoice)
    active.where(invoice_id: invoice.id).sum(:amount)
  end

  # TEN-003: 처리자 휴대폰번호 원문 저장 금지 — CashReceipt#issued_by=와 동일 마스킹
  def confirmed_by=(value)
    super(masked_operator(value))
  end

  def cancelled_by=(value)
    super(masked_operator(value))
  end

  private

  def paid_on_not_in_future
    return if paid_on.blank?

    errors.add(:paid_on, :future_date) if paid_on > Date.current
  end

  def tenant_matches_invoice
    return if tenant.blank? || invoice.blank?
    return if tenant_id == invoice.tenant_id

    errors.add(:tenant, :tenant_mismatch)
  end

  # INV-003: 취소 청구 수납 불가
  def invoice_accepts_payment
    return if invoice.blank?
    return unless invoice.CANCELLED?

    errors.add(:invoice, :cancelled_invoice)
  end

  # PAY-001: 완납(active 합계 >= 총액) 이후 추가 active 수납 거절.
  # 동시성 방어는 서비스 트랜잭션 + 3-S DB 제약으로 보강(_workspace/parallel/f4/03_implementation.md 참조).
  def reject_when_already_paid
    return if invoice.CANCELLED? # 별도 오류(cancelled_invoice)로 안내
    return if Payment.active.where(invoice_id: invoice.id).sum(:amount) < invoice.total_amount

    errors.add(:base, :already_fully_paid)
  end

  # PAY-002: 취소 이력의 상태 복원(재취소·부활) 금지
  def no_resurrection_of_cancelled
    return unless status_was == "cancelled" && status != "cancelled"

    errors.add(:status, :already_cancelled)
  end

  def masked_operator(value)
    raw = value.to_s
    return value unless raw.match?(/\A01[016789]\d{7,8}\z/)

    "#{raw[0, 3]}-****-#{raw[-4, 4]}"
  end
end
