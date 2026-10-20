# frozen_string_literal: true

# 발송 오케스트레이션 (F3 납부 안내 알림톡).
# - MSG-001: 발송 유일성 — MessageLog [invoice, template_type] 검증(재발송은 resend_of 설정)
# - MSG-007: 즉시/예약 발송 — 예약은 MessageSendJob set(wait_until:) 대기열, 취소 가능
# - MSG-002: 대체발송은 솔라피 단일 요청으로 위임(Client — kakaoOptions.disableSms=false + from)
# - 연습 모드(practice)·솔라피 키 미설정 시 실호출 없이 SIMULATED 처리
class Notifications::Dispatcher
  Result = Data.define(:queued, :duplicated, :recipients_missing, :dispatched_invoice_ids)

  def initialize(tenant:)
    @tenant = tenant
  end

  # invoices: 발송 대상 청구 컬렉션(READY)
  # options: template_type(기본 invoice_notice), send_at(Time|nil — 예약발송), resend(MessageLog|nil)
  def dispatch(invoices, template_type: :invoice_notice, send_at: nil, resend: nil)
    queued = 0
    duplicated = 0
    missing = 0
    dispatched_invoice_ids = []

    invoices.each do |invoice| # Relation·Array 모두 지원(스케줄러는 인메모리 필터 배열 전달)
      outcome = dispatch_one(invoice, template_type:, send_at:, resend:)
      case outcome
      when :queued
        queued += 1
        dispatched_invoice_ids << invoice.id
      when :duplicated then duplicated += 1
      when :missing then missing += 1
      end
    end

    Result.new(queued:, duplicated:, recipients_missing: missing,
               dispatched_invoice_ids:)
  end

  # 예약발송 취소(MSG-007): 대기열(QUEUED) 건만 — 예약 잡 삭제 + 로그 폐기 + 청구 READY 복귀
  def cancel_scheduled(log)
    return false unless log.cancellable?

    if log.job_id.present?
      SolidQueue::Job.where(active_job_id: log.job_id).find_each(&:discard)
    end
    if log.invoice.sent_at.blank?
      log.invoice.update!(status: :READY) # 발송 완료 전이므로 발송 대기로 복귀
    end
    log.destroy!
    true
  end

  private

  # 건별 처리 — 독립 savepoint로 진행 보장. MSG-001 유일성은 모델 검증 +
  # partial unique index(CRITICAL-1) 2중이며, 동시 요청 경쟁에서의
  # ActiveRecord::RecordNotUnique도 duplicated로 흡수한다.
  def dispatch_one(invoice, template_type:, send_at:, resend:)
    phone = recipient_phone(invoice)
    return :missing if phone.blank?

    log = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      log = MessageLog.create!(
        tenant: @tenant,
        invoice:,
        student: invoice.student,
        channel: :alimtalk,
        template_type:,
        status: :QUEUED,
        resend_of: resend
      )

      job = MessageSendJob.set(wait_until: send_at).perform_later(log.id) if send_at.present?
      job ||= MessageSendJob.perform_later(log.id)
      log.update!(job_id: job.job_id) # MSG-007 예약 취소용 식별자
    end
    :queued
  rescue ActiveRecord::RecordNotUnique
    :duplicated
  rescue ActiveRecord::RecordInvalid => e
    e.record.errors.of_kind?(:base, :duplicate_dispatch) ? :duplicated : :invalid
  end

  # 수신번호: 대표 보호자 휴대폰번호(복호화). 보호자 부재 시 발송 불가.
  def recipient_phone(invoice)
    guardian = invoice.student.primary_guardian
    guardian&.phone_number
  end
end
