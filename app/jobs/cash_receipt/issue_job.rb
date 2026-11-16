# F5 현금영수증 발행 큐 처리(바로빌 RegistAndIssueCashBill — PRD 10.2).
# - CR-002: 트리거는 입금 확인(F4)/원장 수동 경유 CashReceipt::Triggerable 뿐
# - CR-003: 발행 요청 성공(1)이라도 ISSUED 전이는 하지 않는다 — SyncJob이 barobill_state 폴링으로 확정
# - CR-004: 재시도 전 어댑터 상태 재조회로 기발행 여부 확인(중복 발행 방어)
# - CR-006: 자동 재시도 1회 한도, 소진 시 FAILED + 원장 이중 알림(CashReceipt::Notifier)
class CashReceipt::IssueJob < ApplicationJob
  queue_as :default

  MAX_AUTO_RETRIES = 1 # CR-006 (MSG-003과 동일 한도)

  def perform(cash_receipt_id)
    receipt = CashReceipt.find_by(id: cash_receipt_id)
    return if receipt.nil? || terminal_state?(receipt)

    # 이전 실행이 이미 요청 완료(B1) — SyncJob 재예약으로 폴링 확정
    return CashReceipt::SyncJob.perform_later(receipt.id) if receipt.processing?

    receipt.mark_processing!

    service = issue_service_for(receipt)
    result = service.regist_and_issue(mgt_key: receipt.mgt_key, cash_bill: cash_bill_for(receipt))

    if result.success?
      # CR-003: 처리 중 상태 유지 → 즉시 상태 폴링(SIMULATED는 3000으로 즉시 issued 확정)
      CashReceipt::SyncJob.perform_later(receipt.id)
    else
      handle_failure(receipt, result)
    end
  rescue Barobill::Error => e
    receipt = CashReceipt.find_by(id: cash_receipt_id)
    handle_failure(receipt, Barobill::BaseService::Result.failure(e.code || :api_error, e.message)) if receipt
  end

  private

  def terminal_state?(receipt)
    receipt.issued? || receipt.cancelled? || receipt.cancel_pending? || receipt.needs_info?
  end

  def issue_service_for(receipt)
    tenant = receipt.tenant
    Barobill::CashReceiptService.from_credentials_with_tenant(tenant)
  end

  # CashBillEx 구성(PRD 10.2 필수 필드) — 테넌트(가맹점)·보호자(수취인) 정보 결합
  def cash_bill_for(receipt)
    tenant = receipt.tenant
    {
      FranchiseCorpNum: tenant.business_number,
      FranchiseMemberID: tenant.barobill_member_id,
      FranchiseCorpName: tenant.name,
      FranchiseCEOName: tenant.owner_name,
      FranchiseAddr: tenant.address,
      FranchiseTel: tenant.biz_tel,
      IdentityNum: receipt.identity_num,
      TradeDate: Time.current.strftime("%Y%m%d%H%M%S"), # 발행 시점 — D-1 이내 항상 만족
      TradeType: "N",
      TradeUsage: receipt.expense_evidence? ? "2" : "1", # 1=소득공제 / 2=지출증빙
      TradeMethod: Barobill::CashReceiptService::TRADE_METHOD_MOBILE,
      Amount: receipt.amount,
      Tax: receipt.tax,
      ServiceCharge: receipt.service_charge,
      ItemName: receipt.item_name
    }
  end

  # CR-004: 재시도 전 공급자 상태 재조회 — 이미 발행 완료면 중복 요청 스킵.
  # CR-006: 재시도 1회 한도, 소진 시 FAILED 확정 + 원장 이중 알림.
  def handle_failure(receipt, result)
    existing = lookup_existing_state(receipt)

    if existing&.dig(:barobill_state) == 3000
      # 기발행 확인 — failed로 표시하지 않고 발행 완료 확정(CR-004)
      CashReceipt::SyncJob.perform_later(receipt.id)
      return
    end

    if executions <= MAX_AUTO_RETRIES
      # R2(CR-006): pending 복귀 후 재시도 — 2회째가 processing 가드(라인 16)를 우회해
      # mark_processing! 경유로 실제 재발행을 수행하고, 소진 시 failed+알림 분기에 도달한다
      receipt.update!(state: :pending)
      retry_job(wait: 30.seconds)
    else
      receipt.mark_failed!(result.message || result.code)
      CashReceipt::Notifier.notify_failure(receipt)
    end
  end

  def lookup_existing_state(receipt)
    service = issue_service_for(receipt)
    result = service.state(mgt_key: receipt.mgt_key)
    result.success? ? result.value : nil
  rescue Barobill::Error
    nil
  end
end
