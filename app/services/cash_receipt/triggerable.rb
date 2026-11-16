# F5 발행 트리거 인터페이스(PRD 14장 W3 F5 확정 사항).
# CR-002: 자동발행 트리거는 '입금 확인'(F4/Payment)뿐 — F4 착수 시 Payments::ConfirmService가
# 본 메서드를 호출한다. 이번 실행(F5 단독)은 원장 수동 발행 경로(컨트롤러 issue 액션)로 검증.
# CR-001: 기존 mgt_key 존재 시 skip(어떤 경로로도 중복 발행 불가).
class CashReceipt::Triggerable
  Result = Data.define(:receipt, :outcome) do
    def created? = outcome == :created
    def duplicate? = outcome == :duplicate
    def blocked? = outcome == :blocked
    def needs_info? = outcome == :needs_info
  end

  # invoice: 발행 대상 청구 / issued_by: 처리자 표기(원장 휴대폰번호 — 마스킹 저장, 모델에서 강제).
  # origin: :auto(입금 확인 트리거)·:manual(원장 수동) — CR-002 경로별 정책(C3)은 Invoice가 판정.
  def self.trigger_issue_for(invoice, issued_by:, origin: :manual)
    return Result.new(receipt: nil, outcome: :blocked) unless invoice.cash_receipt_issuable?(origin: origin)

    issue_type = invoice.student.cash_receipt_issue_type.presence || "income_deduction"
    mgt_key = CashReceipt.build_mgt_key(invoice, issue_type)

    if (existing = CashReceipt.find_by(mgt_key: mgt_key)) # CR-001 멱등
      return Result.new(receipt: existing, outcome: :duplicate)
    end

    begin
      receipt = CashReceipt.create!(
        tenant: invoice.tenant,
        invoice: invoice,
        mgt_key: mgt_key,
        issue_type: issue_type,
        state: :pending,
        amount: invoice.total_amount,
        tax: 0,
        service_charge: 0,
        item_name: "#{invoice.target_month} 원비",
        trade_date: Time.current, # TradeDate D-1 제약 — 트리거 시점 일시
        issued_by: issued_by
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # W6: find_by→create! 레이스 — 모델 유니크 검증·DB 유니크 인덱스(CR-001) 어느 쪽이든
      # 승자 건으로 duplicate 응답 통일. 중복이 아닌 다른 검증 실패는 원 예외 유지.
      duplicate = CashReceipt.find_by(mgt_key: mgt_key)
      raise if duplicate.nil?

      return Result.new(receipt: duplicate, outcome: :duplicate)
    end

    # 수취인 식별번호 확정 — 미비 시 needs_info(큐 진입 없음, 원장 정보 보완 대기)
    receipt.resolve_identity_num!
    CashReceipt::IssueJob.perform_later(receipt.id) if receipt.pending?

    Result.new(receipt: receipt, outcome: receipt.needs_info? ? :needs_info : :created)
  end
end
