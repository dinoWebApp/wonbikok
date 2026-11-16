# 발행 취소(F5 — CR-005: 취소는 원본 발행과 연결된 이력, CancelMgtKey로 추적).
# 사유 필수 → cancel_pending → 어댑터 CancelCashBillEx(전건)/PartialEx(부분) → 결과 반영.
# 국세청 처리 기준(PRD 10.2): 실환경은 cancel_pending 유지 후 SyncJob 7000 폴링으로 취소 확정,
# SIMULATED는 즉시 cancelled.
class CashReceipt::CancelService
    Result = Data.define(:success?, :receipt, :message) do
      def self.ok(receipt) = new(success?: true, receipt: receipt, message: nil)
      def self.failure(receipt, message) = new(success?: false, receipt: receipt, message: message)
    end

    def initialize(receipt)
      @receipt = receipt
    end

    # reason: 취소 사유(필수 — 원장 UI 강제 + 서버 검증).
    # amounts: nil이면 전건 취소, 지정하면 부분 취소.
    def call(reason:, amount: nil, tax: nil, service_charge: nil)
      return Result.failure(@receipt, I18n.t("cash_receipts.cancel.errors.reason_blank")) if reason.to_s.strip.blank?
      return Result.failure(@receipt, I18n.t("cash_receipts.cancel.errors.not_cancellable")) unless @receipt.cancellable?

      cancel_mgt_key = @receipt.build_cancel_mgt_key
      @receipt.update!(state: :cancel_pending, cancel_reason: reason.strip, cancel_mgt_key: cancel_mgt_key)

      begin
        result = request_cancel(cancel_mgt_key, amount, tax, service_charge)
      rescue Barobill::Error => e
        # C2(CR-005): 어댑터 예외도 기존 실패 분기와 동일하게 균일 처리 —
        # cancel_pending 고착·컨트롤러 500 방지
        result = Barobill::BaseService::Result.failure(e.code || :api_error, e.message)
      end
      if result.success?
        finalize_success(cancel_mgt_key)
      else
        @receipt.update!(state: :issued, last_error: result.message.to_s) # 취소 실패 — 원본 상태 복원
        Result.failure(@receipt, result.message.to_s)
      end
    end

    private

    def request_cancel(cancel_mgt_key, amount, tax, service_charge)
      @service = Barobill::CashReceiptService.from_credentials_with_tenant(@receipt.tenant)
      if amount.present?
        @service.partial_cancel(mgt_key: @receipt.mgt_key, cancel_mgt_key: cancel_mgt_key,
                                amount: amount, tax: tax || 0, service_charge: service_charge || 0)
      else
        @service.cancel(mgt_key: @receipt.mgt_key, cancel_mgt_key: cancel_mgt_key)
      end
    end

    def finalize_success(_cancel_mgt_key)
      if @service.simulated?
        # SIMULATED — 국세청 처리 없이 즉시 취소 완료
        @receipt.update!(state: :cancelled, cancelled_at: Time.current)
      else
        # 실환경 — CR-003: 7000(취소 완료) 폴링으로 확정
        CashReceipt::SyncJob.perform_later(@receipt.id)
      end
      Result.ok(@receipt)
    end
end
