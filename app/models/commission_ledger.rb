# 수수료 원장 (F10 — REF-003 실제 징수액 기준·REF-004 결제 시점 스냅샷 보존).
# - 결제(SubscriptionEvent manual_payment) 성공 시점에만 생성(append-only — 수정·삭제 경로 미제공).
#   요율 변경·역할 변경의 소급 영향 없음: base_amount·rate·amount는 결제 시점 값 그대로.
# - 월 단위 후불 정산: status pending → paid(관리자 지급 확정 — 사유·감사 로그 병행, ADM-001).
# - v1.0 환불 차감(ledger 역분)은 후속 과제 — refund 이벤트와의 정산은 03_implementation.md 명시.
class CommissionLedger < ApplicationRecord
  STATUS_PENDING = "pending"
  STATUS_PAID = "paid"

  enum :status, { pending: STATUS_PENDING, paid: STATUS_PAID }, validate: true

  belongs_to :sales_rep
  belongs_to :tenant
  belongs_to :source_subscription_event, class_name: "SubscriptionEvent", optional: true,
                                         inverse_of: nil

  validates :month, presence: true, format: { with: /\A\d{4}-\d{2}\z/, message: :invalid_month }
  validates :base_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validate :paid_status_requires_paid_at

  scope :for_month, ->(month) { where(month: month) }
  scope :for_year, ->(year) { where("month LIKE ?", "#{year}-%") }
  scope :recent, -> { order(:month, :id) }

  private

  def paid_status_requires_paid_at
    return unless status == STATUS_PAID
    return if paid_at.present?

    errors.add(:paid_at, :blank)
  end
end
