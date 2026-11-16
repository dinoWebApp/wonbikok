# 발행 이벤트 알림(F5 — PRD 10.3 솔라피 알림톡 스택 재사용).
# - notify_issued: 학부모 발행 안내(cash_receipt_issued 템플릿 — 승인번호·금액)
# - notify_failure: 원장 실패 이중 알림(CR-006)
# ※ 알림톡 실심사 등록 전까지는 SIMULATED 기록(외부 발송 없음) — 템플릿 심사 후
#   MessageSendJob 연결로 전환하는 운영 과제(03_implementation.md 리스크 참조).
class CashReceipt::Notifier
    # 발행 완료 학부모 안내 — issued 확정 시 1회(MSG-001 유일성은 MessageLog 검증이 강제)
    def self.notify_issued(receipt)
      record(receipt, template_type: :cash_receipt_issued)
    end

    # 발행 실패 원장 알림(CR-006) — 학부모 아닌 원장 기록. invoice 스코프 유일성은 동일 적용.
    def self.notify_failure(receipt)
      record(receipt, template_type: :cash_receipt_failed)
    end

    def self.record(receipt, template_type:)
      invoice = receipt.invoice
      MessageLog.create!(
        tenant: invoice.tenant,
        invoice: invoice,
        student: invoice.student,
        channel: :alimtalk,
        template_type: template_type,
        status: :SIMULATED,
        error_code: "SIMULATED",
        error_message: I18n.t("cash_receipts.simulated_note"),
        sent_at: Time.current
      )
    rescue ActiveRecord::RecordInvalid
      nil # 중복(이미 기록된 알림) — 유일성 보장에 의한 무시
    end
end
