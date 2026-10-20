# 월간 청구 (PRD 7장 F3, 9.1 상태 모델).
# 확정 시점 스냅샷 보유(TEN-004) — 원생 설정 변경이 과거 청구를 바꾸지 않는다.
# [student_id, target_month] 유니크 제약으로 INV-001 강제.
class Invoice < ApplicationRecord
  # PRD 9.1 — PARTIALLY_PAID·PAID는 W3 수납(PAY) 도입 시 활성화
  enum :status, {
    DRAFT: "DRAFT",       # 초안: 자동 생성·미확정, 금액 수정 자유
    READY: "READY",       # 발송 대기: 확정 완료, 발송 전
    SENT: "SENT",         # 발송 완료
    UNPAID: "UNPAID",     # 미납(기한 도래 전 미수납)
    OVERDUE: "OVERDUE",   # 기한 초과(리마인더 대상)
    CANCELLED: "CANCELLED" # 취소(수납 합계 제외 — INV-003)
  }, validate: true

  # INV-002: 확정 후 수정 사유(비컬럼 가상 어트리뷰트 — 422 재렌더 시 폼 바인딩용)
  attr_accessor :change_reason

  belongs_to :tenant
  belongs_to :student
  has_many :message_logs, dependent: :destroy

  validates :target_month, presence: true, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/, message: :invalid_month }
  validates :student_name_snapshot, presence: true
  validates :base_amount, numericality: { greater_than_or_equal_to: 0 }
  validates :adjustment_amount, numericality: { greater_than_or_equal_to: -1_000_000_000, less_than_or_equal_to: 1_000_000_000 }
  validates :student_id, uniqueness: { scope: :target_month } # INV-001 모델 레벨(DB 인덱스 병행)

  scope :for_month, ->(month) { where(target_month: month) }
  scope :billable, -> { where.not(status: :CANCELLED) } # INV-003: 취소 청구는 수납 합계 제외
  scope :sendable, -> { where(status: :READY) }

  # F6 리마인더 대상(W2 임시 규칙 — PRD 14장): SENT/UNPAID/OVERDUE & 기한 경과 & 완납 기록 없음
  # (Payment 도입 W3에서 확장) & 취소 제외(INV-003) & 리마인더 제외 원생 배제(MSG-004).
  # 경과일·단계 판정은 Reminders::Scheduler가 담당.
  scope :remindable, -> {
    where(status: [ :SENT, :UNPAID, :OVERDUE ])
      .where.not(due_on: nil)
      .joins(:student)
      .where(students: { excluded_from_reminders: false })
  }

  def total_amount
    base_amount.to_i + adjustment_amount.to_i
  end

  # 기한 경과일(0 = 미경과) — 리마인더 단계 판정·미납 목록 표시용
  def days_overdue(on: Date.current)
    return 0 if due_on.blank? || due_on >= on

    (on - due_on).to_i
  end

  def cancellable?
    DRAFT? || READY? || SENT? || UNPAID? || OVERDUE?
  end

  # 초안(DRAFT) → 확정(READY). INV-006: 발송 전까지 미리보기·수정 가능
  def confirm!
    return false unless DRAFT?

    update!(status: :READY)
  end

  # 청구 취소(INV-003): 사유 필수, 수납 합계에서 제외.
  # 예약 발송 대기(QUEUED) 중인 안내는 연쇄 취소 — 취소 청구 발송 차단(9.1).
  def cancel!(reason)
    if reason.to_s.strip.blank?
      errors.add(:cancel_reason, :blank)
      return false
    end
    return false unless cancellable?

    transaction do
      update!(status: :CANCELLED, cancelled_at: Time.current, cancel_reason: reason.strip)
      message_logs.QUEUED.find_each do |log|
        SolidQueue::Job.where(active_job_id: log.job_id).find_each(&:discard) if log.job_id.present?
        log.update!(status: :FAILED, error_code: "INVOICE_CANCELLED",
                    error_message: I18n.t("messages.errors.invoice_cancelled"))
      end
    end
    true
  end

  # 금액 조정. DRAFT는 자유 수정, READY는 변경 사유 필수(INV-002)·이력 기록.
  # INV-006: 발송(SENT) 이후·취소(CANCELLED) 청구는 조정할 수 없다.
  def adjust!(adjustment_amount:, adjustment_note:, change_reason: nil)
    unless DRAFT? || READY?
      errors.add(:status, :invalid)
      return false
    end

    if !DRAFT? && change_reason.to_s.strip.blank?
      errors.add(:change_reason, :blank)
      return false
    end

    self.adjustment_amount = adjustment_amount
    self.adjustment_note = adjustment_note
    record_change_history!(change_reason) if !DRAFT? && changed?
    save
  end

  # 발송 완료 전이(MessageSendJob 성공 시 호출). READY 이전 전이 방지 가드.
  def mark_sent!
    return false unless READY? || SENT?

    update!(status: :SENT, sent_at: Time.current)
  end

  def change_history_entries
    return [] if change_history.blank?

    JSON.parse(change_history)
  rescue JSON::ParserError
    []
  end

  private

  def record_change_history!(reason)
    entries = change_history_entries
    entries << {
      "at" => Time.current.iso8601,
      "reason" => reason.to_s.strip,
      "adjustment_amount" => adjustment_amount,
      "adjustment_note" => adjustment_note
    }
    self.change_history = JSON.generate(entries)
  end
end
