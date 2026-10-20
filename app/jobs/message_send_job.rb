# 메시지 발송 큐 처리 (F3, PRD 10.2 솔라피 Messages v4).
# - 연습 모드(practice 테넌트)·솔라피 키 미설정: 실호출 없이 SIMULATED 기록
# - MSG-002: 알림톡 실패 시 SMS/LMS 대체발송은 솔라피 단일 요청으로 위임(disableSms=false)
# - MSG-003: 자동 재시도 상한 1회 — 네트워크·서버 오류만 1회 재시도, 그 외 즉시 FAILED
class MessageSendJob < ApplicationJob
  queue_as :default

  MAX_AUTO_RETRIES = 1 # MSG-003

  def perform(message_log_id)
    log = MessageLog.find_by(id: message_log_id)
    return if log.nil? || log.dispatched?

    # INV-003/9.1: 취소된 청구는 발송하지 않는다(예약 큐 잔존 방어)
    if log.invoice.CANCELLED?
      record_failure!(log, "INVOICE_CANCELLED", I18n.t("messages.errors.invoice_cancelled"))
      return
    end

    log.update!(status: :SENDING)

    phone = log.student.primary_guardian&.phone_number
    return record_failure!(log, "NO_RECIPIENT", I18n.t("messages.errors.no_recipient")) if phone.blank?

    if simulated?(log)
      record_simulated!(log)
      return
    end

    client = Solapi::Client.from_credentials
    builder = if MessageLog::REMINDER_TEMPLATE_TYPES.include?(log.template_type.to_sym)
                # F6 리마인더 — 단계 템플릿·커스텀 문구·톤(테넌트 설정) 적용
                Solapi::MessageBuilder.reminder(
                  invoice: log.invoice, tenant: log.tenant,
                  template_type: log.template_type.to_sym, to: phone
                )
    else
                Solapi::MessageBuilder.invoice_notice(
                  invoice: log.invoice, tenant: log.tenant, to: phone
                )
    end
    message = builder.to_message(to: phone)

    result = client.send_messages([ message ], scheduled_date: nil)

    if result.success?
      log.update!(
        status: result.fallback? ? :FALLBACK_SENT : :SENT, # MSG-002 채널 구분 표시
        provider_message_id: result.message_id,
        sent_at: Time.current
      )
      mark_invoice_sent!(log)
    elsif result.error_code == "NETWORK_ERROR" # 일시적 장애 — 재시도 대상
      handle_retry_or_fail(log, result.error_code, result.error_message)
    else
      record_failure!(log, result.error_code, result.error_message)
    end
  rescue Solapi::Client::ConfigError => e
    # 키 오류는 재시도해도 동일 — 즉시 실패 확정
    record_failure!(log, "CONFIG_ERROR", e.message)
  rescue Solapi::Client::Error => e
    handle_retry_or_fail(log, "API_ERROR", e.message)
  end

  private

  # 연습 모드 또는 credentials 미설정 → 실호출 금지, SIMULATED 기록
  def simulated?(log)
    return true if log.tenant.practice?

    config = Rails.application.config_for(:solapi)
    config[:api_key].blank? || config[:api_secret].blank?
  rescue StandardError
    true
  end

  def record_simulated!(log)
    log.update!(status: :SIMULATED, sent_at: Time.current,
                error_code: "SIMULATED", error_message: I18n.t("messages.simulated_note"))
    mark_invoice_sent!(log)
  end

  def record_failure!(log, code, message)
    log.update!(status: :FAILED, error_code: code.to_s, error_message: message)
  end

  # MSG-003: 재시도 상한 1회 — 1회 소진 후 FAILED 확정
  def handle_retry_or_fail(log, code, message)
    if executions < MAX_AUTO_RETRIES
      retry_job(wait: 5.minutes)
    else
      record_failure!(log, code, message)
    end
  end

  def mark_invoice_sent!(log)
    invoice = log.invoice
    invoice.mark_sent! if invoice.READY?
  end
end
