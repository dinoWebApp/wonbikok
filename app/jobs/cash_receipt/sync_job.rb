# F5 발행 상태 동기화(바로빌 GetCashBillInfo 폴링 — PRD 10.2).
# - CR-003: barobill_state 3000(국세청 전송 완료) 확인 시에만 ISSUED 전이(승인번호 수령)
# - 4000 전송 실패 → FAILED(사유) / 7000 취소 → CANCELLED
# - C1: 비종결 상태(2000/2500·폴링 실패)는 wait 단계 증가(30s→1m→5m→10m)로 재폴링 —
#   무한 루프 방지를 위해 MAX_POLLS 상한 초과 시 재예약 중단(수동 재시도 대기)
# - ISSUED 확정 시 학부모 발행 안내 알림톡 1회(CR-003·MSG 유일성은 MessageLog 검증이 담당)
class CashReceipt::SyncJob < ApplicationJob
  queue_as :default

  MAX_POLLS = 6 # 무한 폴링 방지 상한(C1)
  POLL_WAITS = [ 30.seconds, 1.minute, 5.minutes, 10.minutes ].freeze # 단계 증가 — 상한 도달 후 마지막 값 유지

  def perform(cash_receipt_id, poll_count = 0)
    receipt = CashReceipt.find_by(id: cash_receipt_id)
    return if receipt.nil?
    return unless receipt.processing? || receipt.cancel_pending?

    service = Barobill::CashReceiptService.from_credentials_with_tenant(receipt.tenant)
    result = service.state(mgt_key: receipt.mgt_key)
    return handle_poll_error(receipt, result, poll_count) unless result.success?

    apply_state(receipt, result.value, poll_count)
  end

  private

  def apply_state(receipt, info, poll_count)
    case info[:barobill_state]
    when 3000
      # W2: mark_issued! 가드 실패 시 전이·알림 모두 미실행
      if receipt.mark_issued!(nts_confirm_num: info[:nts_confirm_num], barobill_state: 3000)
        CashReceipt::Notifier.notify_issued(receipt) # 학부모 발행 안내 — MessageLog(SIMULATED) 기록
      elsif receipt.cancel_pending?
        # R1(CR-005): 취소 요청 직후 첫 폴링은 원본이 아직 3000 — 7000(취소 완료) 확정까지 폴링 지속
        reschedule_poll(receipt, poll_count)
      end
    when 4000
      receipt.update!(
        state: receipt.cancel_pending? ? :issued : :failed, # 취소 실패는 원본 상태 유지
        barobill_state: 4000,
        last_error: info[:nts_confirm_message].presence || "BAROBILL_STATE_4000"
      )
      CashReceipt::Notifier.notify_failure(receipt) unless receipt.cancel_pending? || receipt.issued?
    when 7000
      receipt.update!(state: :cancelled, barobill_state: 7000, cancelled_at: Time.current)
    else
      # 1000/2000/2500(임시·발급·전송 중)은 비종결 — processing/cancel_pending 유지 후 재폴링(C1)
      reschedule_poll(receipt, poll_count)
    end
  end

  # C1: wait 단계 증가 재예약. 상한 초과 시 중단(MSG-003 무한 재시도 금지 준용)
  def reschedule_poll(receipt, poll_count)
    if poll_count >= MAX_POLLS
      Rails.logger.warn("[CashReceipt::SyncJob] poll limit reached mgt_key=#{receipt.mgt_key} — 수동 확인 필요")
      return
    end

    self.class.set(wait: POLL_WAITS[poll_count] || POLL_WAITS.last).perform_later(receipt.id, poll_count + 1)
  end

  # 폴링 실패(네트워크·API 오류) — 상태 유지 후 단계 증가 재폴링(C1)
  def handle_poll_error(receipt, result, poll_count)
    receipt.touch
    Rails.logger.warn("[CashReceipt::SyncJob] poll failed mgt_key=#{receipt.mgt_key} code=#{result.code}")
    reschedule_poll(receipt, poll_count)
  end
end
