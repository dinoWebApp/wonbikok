# 메시지 발송 이력 (PRD 9.3 상태 모델, 10.2 솔라피).
# 발송 유일성(MSG-001): 원생 × 당월(=청구) × 템플릿 유형 1건 — '다시 보내기'(resend_of)만 예외.
class MessageLog < ApplicationRecord
  enum :status, {
    QUEUED: "QUEUED",             # 대기(예약 포함 — MSG-007 대기열 표시)
    SENDING: "SENDING",           # 발송 중
    SENT: "SENT",                 # 성공(알림톡)
    FAILED: "FAILED",             # 실패(사유 코드 기록)
    FALLBACK_SENT: "FALLBACK_SENT", # 알림톡 실패 → SMS/LMS 대체 발송 성공(MSG-002)
    SIMULATED: "SIMULATED"        # 연습 모드·키 미설정(실호출 없음)
  }, validate: true

  enum :channel, { alimtalk: "alimtalk", sms: "sms" }, validate: true

  # F6 리마인더: 단계별 template_type — MSG-001 유일성(청구 × 템플릿 유형)이 단계당 1회를 강제
  enum :template_type, {
    invoice_notice: "invoice_notice",
    reminder_d3: "reminder_d3",
    reminder_d7: "reminder_d7",
    reminder_month_end: "reminder_month_end"
  }, validate: true

  REMINDER_TEMPLATE_TYPES = %i[reminder_d3 reminder_d7 reminder_month_end].freeze

  belongs_to :tenant
  belongs_to :invoice
  belongs_to :student
  belongs_to :resend_of, class_name: "MessageLog", optional: true
  has_many :resends, class_name: "MessageLog", foreign_key: :resend_of_id, inverse_of: :resend_of

  validates :template_type, presence: true

  # MSG-001: 동일 청구 × 템플릿 유형 중복 발송 방지(재발송은 resend_of 있는 건만 허용)
  validate :dispatch_uniqueness, on: :create

  scope :scheduled_queue, -> { QUEUED.order(:created_at) }
  scope :reminder, -> { where(template_type: REMINDER_TEMPLATE_TYPES) } # F6 리마인더 이력
  scope :for_month_of, ->(invoice) { where(invoice: Invoice.for_month(invoice.target_month)) }

  def dispatched?
    SENT? || FALLBACK_SENT? || SIMULATED?
  end

  def failed?
    FAILED?
  end

  # MSG-007: 대기열(QUEUED) 건 취소 가능
  def cancellable?
    QUEUED?
  end

  private

  def dispatch_uniqueness
    return if resend_of_id.present? # 명시적 재발송은 예외(이력 연결)

    exists = MessageLog.where(invoice_id: invoice_id, template_type: template_type).exists?
    errors.add(:base, :duplicate_dispatch) if exists
  end
end
